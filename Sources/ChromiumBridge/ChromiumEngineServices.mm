// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumEngineServices.h"
#import "../../ThirdParty/ArdiaCore/ac_engine.h"
#include <dlfcn.h>
#include <string.h>

static NSDictionary *ServiceJSON(const char *json) {
  if (!json) return nil;
  NSData *data = [NSData dataWithBytes:json length:strlen(json)];
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void ServiceReply(void *context, const char *json) {
  void (^done)(NSDictionary *) = (__bridge_transfer void (^)(NSDictionary *))context;
  done(ServiceJSON(json) ?: @{@"error": @"Invalid engine service response."});
}

@interface ARCEngineServices ()
- (void)receiveTopic:(NSString *)topic payload:(NSDictionary *)payload;
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
  NSMutableDictionary *calls = [NSMutableDictionary dictionary];
  for (NSString *method in methods) {
    NSString *symbol = [@"ac_" stringByAppendingString:[method stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
    void *address = dlsym(library, symbol.UTF8String);
    if (address) calls[method] = [NSValue valueWithPointer:address];
  }
  if (!version || version() != AC_ENGINE_ABI_VERSION || !_setSink || calls.count != methods.count) {
    if (error) *error = [NSError errorWithDomain:@"com.arcusis.browser.services" code:1
      userInfo:@{NSLocalizedDescriptionKey: @"The engine does not expose the pinned profile service ABI."}];
    return nil;
  }
  _calls = calls;
  _paths = [NSMutableDictionary dictionary];
  _profilesByPath = [NSMutableDictionary dictionary];
  return self;
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
      userInfo:@{NSLocalizedDescriptionKey: @"The engine profile could not be verified."}];
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
    completion(@{@"error": @"Unknown engine profile or service."});
    return;
  }
  call(path.UTF8String, json.UTF8String, ServiceReply, (__bridge_retained void *)[completion copy]);
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
