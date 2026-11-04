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

static NSMutableDictionary<NSString *, NSURL *> *ShaarDownloadDirectories(ARCShaarRuntime *runtime) {
  NSMutableDictionary *cache = objc_getAssociatedObject(runtime, ShaarDownloadDirectoryKey);
  if (!cache) {
    cache = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, ShaarDownloadDirectoryKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return cache;
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
  [self shaarSubmit:SHAAR_OP_DOWNLOAD_LIST profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1} completion:^(NSDictionary *result, NSError *error) {
    NSArray *downloads = result[@"downloads"];
    if (error || ![downloads isKindOfClass:NSArray.class]) {
      if (self.onNotice) self.onNotice((error ?: [NSError errorWithDomain:@"com.arcusis.browser.downloads"
          code:1 userInfo:@{NSLocalizedDescriptionKey: @"Downloads could not be restored."}]).localizedDescription);
      return;
    }
    for (id row in downloads) if (![row isKindOfClass:NSDictionary.class]) return;
    if (self.onDownloadsRestored) self.onDownloadsRestored(profileID, downloads);
  }];
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
