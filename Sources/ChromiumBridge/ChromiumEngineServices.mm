// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"
#import "ChromiumShaarFeatureTransport.h"
#import <objc/runtime.h>

static NSError *ServiceError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.downloads" code:1
      userInfo:@{NSLocalizedDescriptionKey: ARCBridgeLocalizedString(message)}];
}
static const void *ShaarDownloadDirectoryKey = &ShaarDownloadDirectoryKey;
static const void *ShaarDownloadRetryKey = &ShaarDownloadRetryKey;
static const NSUInteger ShaarDownloadReadinessLimit = 8;
static const int64_t ShaarDownloadRetryDelay = 2500 * NSEC_PER_MSEC;
static NSString * const ShaarDownloadsUnavailableNotice = @"Downloads could not be restored.";

@interface ShaarDownloadReadiness : NSObject
@property(nonatomic) NSUInteger failures;
@property(nonatomic, strong) NSUUID *retryToken;
@end

@implementation ShaarDownloadReadiness
@end

static NSMutableDictionary<NSString *, NSURL *> *ShaarDownloadDirectories(ARCShaarRuntime *runtime) {
  NSMutableDictionary *cache = objc_getAssociatedObject(runtime, ShaarDownloadDirectoryKey);
  if (!cache) {
    cache = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, ShaarDownloadDirectoryKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return cache;
}

static NSMutableDictionary<NSString *, ShaarDownloadReadiness *> *ShaarDownloadRetries(ARCShaarRuntime *runtime) {
  NSMutableDictionary *tokens = objc_getAssociatedObject(runtime, ShaarDownloadRetryKey);
  if (!tokens) {
    tokens = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, ShaarDownloadRetryKey, tokens, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return tokens;
}

static BOOL IsDownloadNotReady(NSError *error) {
  return [error.domain isEqualToString:@"org.arcusis.shaar.engine"] && error.code == SHAAR_NOT_READY;
}

static void RefreshDownloads(ARCShaarRuntime *runtime, NSString *profileID);

static void PublishDownloadListFailure(ARCShaarRuntime *runtime, NSError *error) {
  NSString *message = ShaarDownloadsUnavailableNotice;
  if (error && !IsDownloadNotReady(error)) message = error.localizedDescription;
  if (runtime.onNotice) runtime.onNotice(message);
}

static BOOL ScheduleDownloadListRetry(ARCShaarRuntime *runtime, NSString *profileID) {
  // Startup polls at 300 ms, 700 ms, and 2 s share one timer so they do not burn the budget.
  NSMutableDictionary<NSString *, ShaarDownloadReadiness *> *retries = ShaarDownloadRetries(runtime);
  ShaarDownloadReadiness *readiness = retries[profileID];
  if (!readiness) {
    readiness = [ShaarDownloadReadiness new];
    retries[profileID] = readiness;
  }
  if (readiness.retryToken) return YES;
  readiness.failures += 1;
  if (readiness.failures >= ShaarDownloadReadinessLimit) return NO;
  NSUUID *token = [NSUUID UUID];
  readiness.retryToken = token;
  __weak ARCShaarRuntime *weakRuntime = runtime;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ShaarDownloadRetryDelay), dispatch_get_main_queue(), ^{
    ARCShaarRuntime *owner = weakRuntime;
    if (!owner) return;
    ShaarDownloadReadiness *pending = ShaarDownloadRetries(owner)[profileID];
    if (![pending.retryToken isEqual:token]) return;
    pending.retryToken = nil;
    if ([owner isQuitting] || ![owner shaarHasProfileID:profileID]) {
      [ShaarDownloadRetries(owner) removeObjectForKey:profileID];
      return;
    }
    RefreshDownloads(owner, profileID);
  });
  return YES;
}

static void RefreshDownloads(ARCShaarRuntime *runtime, NSString *profileID) {
  [runtime shaarSubmit:SHAAR_OP_DOWNLOAD_LIST profileID:profileID tabID:nil
              payload:@{@"schemaVersion": @1} completion:^(NSDictionary *result, NSError *error) {
    if (IsDownloadNotReady(error) && ScheduleDownloadListRetry(runtime, profileID)) return;
    [ShaarDownloadRetries(runtime) removeObjectForKey:profileID];
    NSArray *downloads = result[@"downloads"];
    if (!error && [downloads isKindOfClass:NSArray.class]) {
      for (id row in downloads) if (![row isKindOfClass:NSDictionary.class]) return;
      if (runtime.onDownloadsRestored) runtime.onDownloadsRestored(profileID, downloads);
      return;
    }
    PublishDownloadListFailure(runtime, error);
  }];
}

@implementation ARCShaarRuntime (EngineServices)

- (void)shaarPrimeEngineServicesForProfileID:(NSString *)profileID completion:(void (^)(void))completion {
  [self shaarSubmit:SHAAR_OP_DOWNLOAD_DIRECTORY profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"action": @"get"}
        completion:^(NSDictionary *result, NSError *error) {
    NSString *path = result[@"directory"];
    if (!error && [path isKindOfClass:NSString.class] && path.isAbsolutePath)
      ShaarDownloadDirectories(self)[profileID] = [NSURL fileURLWithPath:path isDirectory:YES];
    completion();
  }];
}

- (NSURL *)downloadsDirectoryForProfileID:(NSString *)profileID {
  if (![self shaarHasProfileID:profileID]) return nil;
  return ShaarDownloadDirectories(self)[profileID];
}

- (NSURL *)profileDataDirectoryForProfileID:(NSString *)profileID {
  return [self shaarProfileDirectoryForID:profileID];
}

- (void)configureDownloadDirectory:(NSURL *)directory profileID:(NSString *)profileID
                        completion:(void (^)(NSURL *, NSError *))completion {
  if (![self shaarHasProfileID:profileID] || (directory && !directory.isFileURL)) {
    completion(nil, ServiceError(@"A loaded profile and a local folder are required."));
    return;
  }
  NSMutableDictionary *payload = [@{@"schemaVersion": @1,
    @"action": directory ? @"set" : @"useDefault"} mutableCopy];
  if (directory) payload[@"directory"] = directory.standardizedURL.path;
  [self shaarSubmit:SHAAR_OP_DOWNLOAD_DIRECTORY profileID:profileID tabID:nil payload:payload
        completion:^(NSDictionary *result, NSError *error) {
    NSString *path = result[@"directory"];
    if (error || ![path isKindOfClass:NSString.class] || !path.isAbsolutePath) {
      completion(nil, error ?: ServiceError(@"The download folder could not be saved."));
      return;
    }
    NSURL *effective = [NSURL fileURLWithPath:path isDirectory:YES];
    ShaarDownloadDirectories(self)[profileID] = effective;
    completion(effective, nil);
  }];
}

- (void)downloadCommand:(NSString *)command downloadID:(NSString *)downloadID profileID:(NSString *)profileID
            completion:(void (^)(NSError *))completion {
  if (![@[@"pause", @"resume", @"cancel", @"remove"] containsObject:command] ||
      ![[NSUUID alloc] initWithUUIDString:downloadID]) {
    completion([NSError errorWithDomain:@"com.arcusis.browser.downloads" code:1
        userInfo:@{NSLocalizedDescriptionKey: ARCBridgeLocalizedString(@"Invalid download action.")}]);
    return;
  }
  [self shaarSubmit:SHAAR_OP_DOWNLOAD_CONTROL profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"downloadId": downloadID, @"action": command}
        completion:^(NSDictionary *result, NSError *error) { completion(error); }];
}

- (void)refreshDownloadsForProfileID:(NSString *)profileID {
  if (![self shaarHasProfileID:profileID]) return;
  RefreshDownloads(self, profileID);
}

- (void)shaarReceiveDownloadEventForProfileID:(NSString *)profileID payload:(NSDictionary *)payload {
  if (!profileID || ![self shaarHasProfileID:profileID]) return;
  NSString *kind = payload[@"kind"];
  if ([kind isEqualToString:@"downloads.changed"]) {
    NSDictionary *record = payload[@"download"];
    if ([record isKindOfClass:NSDictionary.class] && self.onDownloadChanged)
      self.onDownloadChanged(profileID, record);
  } else if ([kind isEqualToString:@"downloads.removed"]) {
    NSString *identity = payload[@"downloadId"];
    if ([identity isKindOfClass:NSString.class] && self.onDownloadRemoved)
      self.onDownloadRemoved(profileID, identity);
  }
}

@end
