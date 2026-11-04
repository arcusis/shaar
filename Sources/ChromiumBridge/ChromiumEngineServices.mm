// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumEngineServices.h"
#import "include/ChromiumBridge.h"
#import "../../ThirdParty/ArdiaCore/ac_engine.h"
#import "ChromiumShaarFeatureTransport.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

static NSDictionary *ServiceJSON(const char *json) {
  if (!json) return nil;
  NSData *data = [NSData dataWithBytes:json length:strlen(json)];
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSError *ServiceError(NSString *message) {
  return [NSError errorWithDomain:@"com.arcusis.browser.downloads" code:1
      userInfo:@{NSLocalizedDescriptionKey: ARCBridgeLocalizedString(message)}];
}

static void ServiceReply(void *context, const char *json) {
  void (^done)(NSDictionary *) = (__bridge_transfer void (^)(NSDictionary *))context;
  done(ServiceJSON(json) ?: @{@"error": ARCBridgeLocalizedString(@"Invalid engine service response.")});
}

@interface ARCEngineServices ()
- (void)receiveTopic:(NSString *)topic payload:(NSDictionary *)payload;
@end

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

static void ServiceEvent(void *context, const char *topic, const char *json) {
  if (!topic) return;
  NSString *name = [NSString stringWithUTF8String:topic];
  if (![@[@"downloads.changed", @"downloads.removed", @"bookmarks.changed", @"history.changed"] containsObject:name]) return;
  NSDictionary *payload = ServiceJSON(json);
  if (payload) [(__bridge ARCEngineServices *)context receiveTopic:name payload:payload];
}

@implementation ARCEngineServices {
  ac_engine_set_event_sink_t _setSink;
  NSDictionary<NSString *, NSValue *> *_calls;
  NSMutableDictionary<NSString *, NSString *> *_paths;
  NSMutableDictionary<NSString *, NSString *> *_profilesByPath;
  BOOL _started;
}

- (instancetype)initWithLibrary:(void *)library error:(NSError **)error {
  if (!(self = [super init])) return nil;
  auto version = (ac_engine_abi_version_t)dlsym(library, "ac_engine_abi_version");
  _setSink = (ac_engine_set_event_sink_t)dlsym(library, "ac_engine_set_event_sink");
  NSArray *methods = @[@"downloads.list", @"downloads.pause", @"downloads.resume", @"downloads.cancel", @"downloads.remove",
    @"bookmarks.tree", @"bookmarks.apply", @"bookmarks.watch", @"history.query", @"history.delete_urls", @"history.watch",
    @"site_settings.get", @"site_settings.set", @"site_data.clear", @"browsing_data.clear"];
  NSArray *privateMethods = @[@"private.tracker.rules.set", @"private.privacy.get",
    @"private.tracker.site.set", @"private.tracker.site.get", @"site_settings.set_default"];
  NSMutableDictionary *calls = [NSMutableDictionary dictionary];
  for (NSString *method in [methods arrayByAddingObjectsFromArray:privateMethods]) {
    NSString *symbol = [@"ac_" stringByAppendingString:[method stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    void *address = dlsym(library, symbol.UTF8String);
    if (address) calls[method] = [NSValue valueWithPointer:address];
  }
  BOOL mandatoryAvailable = YES;
  for (NSString *method in methods) mandatoryAvailable = mandatoryAvailable && calls[method] != nil;
  if (!version || version() != AC_ENGINE_ABI_VERSION || !_setSink || !mandatoryAvailable) {
    if (error) *error = [NSError errorWithDomain:@"com.arcusis.browser.services" code:1
      userInfo:@{NSLocalizedDescriptionKey: ARCBridgeLocalizedString(@"The engine does not expose the pinned profile service ABI.")}];
    return nil;
  }
  _calls = calls;
  // These services are exported by the pinned engine but were not required by older shells.
  for (NSString *method in @[@"site_settings.origins", @"site_settings.reset"]) {
    NSString *symbol = [@"ac_" stringByAppendingString:[method stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    void *address = dlsym(library, symbol.UTF8String);
    if (address) calls[method] = [NSValue valueWithPointer:address];
  }
  void *historyImport = dlsym(library, "ac_history_import");
  if (historyImport) calls[@"history.import"] = [NSValue valueWithPointer:historyImport];
  _paths = [NSMutableDictionary dictionary];
  _profilesByPath = [NSMutableDictionary dictionary];
  return self;
}

- (BOOL)privatePrivacyAvailable {
  return _calls[@"private.tracker.rules.set"] && _calls[@"private.privacy.get"] &&
    _calls[@"private.tracker.site.set"] && _calls[@"private.tracker.site.get"] &&
    _calls[@"site_settings.set"] && _calls[@"site_settings.get"] &&
    _calls[@"site_settings.set_default"];
}

- (void)preparePrivateTrackerRulesForProfileID:(NSString *)profileID
  completion:(void (^)(BOOL))completion {
  NSAssert(NSThread.isMainThread, @"Private rules require the UI thread");
  if (!self.privatePrivacyAvailable) { completion(NO); return; }
  NSURL *url = [[NSBundle mainBundle].resourceURL URLByAppendingPathComponent:@"Privacy/tracker-domains.json"];
  NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
  NSDictionary *rules = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSArray *domains = [rules[@"domains"] isKindOfClass:NSArray.class] ? rules[@"domains"] : nil;
  NSString *revision = [rules[@"revision"] isKindOfClass:NSString.class] ? rules[@"revision"] : nil;
  if (![rules[@"schema"] isEqual:@1] || !revision.length || !domains.count || domains.count > 100000) {
    completion(NO); return;
  }
  [self call:@"private.tracker.rules.set" profileID:profileID
    args:@{@"schema": @1, @"revision": revision, @"domains": domains}
    completion:^(NSDictionary *result) {
      completion([result[@"revision"] isEqual:revision] &&
        [result[@"domainCount"] isEqual:@(domains.count)]);
    }];
}

- (void)start {
  NSAssert(NSThread.isMainThread, @"Engine services require the UI thread");
  if (_started) return;
  _started = YES;
  _setSink(ServiceEvent, (__bridge void *)self);
}

- (void)dealloc { if (_started) _setSink(nullptr, nullptr); }

- (BOOL)bindProfileID:(NSString *)profileID path:(NSString *)path error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Profile binding requires the UI thread");
  NSString *canonical = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString *owner = _profilesByPath[canonical];
  if (!_started || ![[NSUUID alloc] initWithUUIDString:profileID] || !path.isAbsolutePath ||
      (owner && ![owner isEqualToString:profileID]) ||
      (_paths[profileID] && ![_paths[profileID] isEqualToString:canonical])) {
    if (error) *error = [NSError errorWithDomain:@"com.arcusis.browser.services" code:2
      userInfo:@{NSLocalizedDescriptionKey: ARCBridgeLocalizedString(@"The engine profile could not be verified.")}];
    return NO;
  }
  _paths[profileID] = canonical;
  _profilesByPath[canonical] = profileID;
  return YES;
}

- (void)call:(NSString *)method profileID:(NSString *)profileID args:(NSDictionary *)args
  completion:(void (^)(NSDictionary *))completion {
  NSAssert(NSThread.isMainThread, @"Engine services require the UI thread");
  NSString *path = _paths[profileID];
  auto call = (ac_engine_call_t)_calls[method].pointerValue;
  NSData *data = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
  NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!_started || !path || !call || !json) {
    completion(@{@"error": ARCBridgeLocalizedString(@"Unknown engine profile or service.")});
    return;
  }
  call(path.UTF8String, json.UTF8String, ServiceReply, (__bridge_retained void *)[completion copy]);
}

- (void)unbindProfileID:(NSString *)profileID {
  NSString *path = _paths[profileID];
  if (path) [_profilesByPath removeObjectForKey:path];
  [_paths removeObjectForKey:profileID];
}

- (void)receiveTopic:(NSString *)topic payload:(NSDictionary *)payload {
  NSAssert(NSThread.isMainThread, @"Engine events require the UI thread");
  // The ABI labels private events with the original profile's path.
  id privateSession = payload[@"offTheRecord"];
  if (privateSession && (![privateSession isKindOfClass:NSNumber.class] || [privateSession boolValue])) return;
  NSString *path = payload[@"profile"];
  if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return;
  NSString *profileID = _profilesByPath[path.stringByStandardizingPath.stringByResolvingSymlinksInPath];
  if (profileID && _onEvent) _onEvent(topic, profileID, payload);
}
@end
