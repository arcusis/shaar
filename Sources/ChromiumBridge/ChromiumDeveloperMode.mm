// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"

@implementation ARCChromiumRuntime (DeveloperMode)
- (BOOL)beginDeveloperSessionForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab || ![_owners[tabID] isEqual:profileID] || ![_tabWindows[tabID] isEqual:windowID]) return NO;
  if (!_developerLeases) _developerLeases = [NSMutableDictionary dictionary];
  if (!_developerLeaseScopes) _developerLeaseScopes = [NSMutableDictionary dictionary];
  NSString *scope = [NSString stringWithFormat:@"%@/%@", profileID, windowID];
  if (_developerLeases[tabID] && [_developerLeaseScopes[tabID] isEqual:scope]) return YES;
  NSString *lease = NSUUID.UUID.UUIDString;
  _developerLeases[tabID] = lease;
  _developerLeaseScopes[tabID] = scope;
  [self holdDeveloperTab:tab tabID:tabID lease:lease];
  return YES;
}

- (void)holdDeveloperTab:(ArdiaCoreTab *)tab tabID:(NSString *)tabID lease:(NSString *)lease {
  if (![self->_developerLeases[tabID] isEqual:lease]) return;
  if ([self liveTabForID:tabID] != tab) {
    [self->_developerLeases removeObjectForKey:tabID];
    [self->_developerLeaseScopes removeObjectForKey:tabID];
    return;
  }
  // The pinned caller detaches when its pending map empties. Overlap bounded calls to retain
  // the session without a debug socket or engine events. Timers expire even after lease end.
  [tab devToolsCall:@"Runtime.evaluate"
            params:@{@"expression": @"new Promise(resolve => setTimeout(resolve, 30000))", @"awaitPromise": @YES}
           timeout:35 completion:^(NSDictionary *result, NSString *error) {}];
  __weak ARCChromiumRuntime *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf holdDeveloperTab:tab tabID:tabID lease:lease];
  });
}

- (void)endDeveloperSessionForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID {
  NSString *scope = [NSString stringWithFormat:@"%@/%@", profileID, windowID];
  if (![_developerLeaseScopes[tabID] isEqual:scope]) return;
  [_developerLeases removeObjectForKey:tabID];
  [_developerLeaseScopes removeObjectForKey:tabID];
}

- (void)developerCall:(NSString *)method params:(NSDictionary *)params tabID:(NSString *)tabID
           profileID:(NSString *)profileID windowID:(NSString *)windowID
          completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  static NSSet *methods;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    methods = [NSSet setWithArray:@[@"Emulation.setDeviceMetricsOverride", @"Emulation.clearDeviceMetricsOverride",
      @"Network.enable", @"Network.emulateNetworkConditions", @"Emulation.setCPUThrottlingRate",
      @"Emulation.setGeolocationOverride", @"Emulation.clearGeolocationOverride",
      @"Emulation.setTimezoneOverride", @"Emulation.setLocaleOverride", @"Emulation.setUserAgentOverride",
      @"Emulation.setEmulatedMedia", @"Runtime.evaluate", @"Performance.enable", @"Performance.getMetrics", @"Page.captureScreenshot",
      @"Page.enable", @"Page.addScriptToEvaluateOnNewDocument", @"Page.removeScriptToEvaluateOnNewDocument",
      @"Network.getCookies", @"Network.setCookie", @"Network.deleteCookies"]];
  });
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab || ![_owners[tabID] isEqual:profileID] || ![_tabWindows[tabID] isEqual:windowID] ||
      ![methods containsObject:method]) {
    completion(nil, ARCBridgeError(@"The developer tools target is no longer available."));
    return;
  }
  [tab devToolsCall:method params:params timeout:10 completion:^(NSDictionary *result, NSString *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (error || result[@"error"]) {
        completion(nil, ARCBridgeError(error ?: [result[@"error"] description]));
      } else if ([self liveTabForID:tabID] != tab || ![self->_owners[tabID] isEqual:profileID] ||
                 ![self->_tabWindows[tabID] isEqual:windowID]) {
        completion(nil, ARCBridgeError(@"The developer tools target changed."));
      } else {
        completion(result ?: @{}, nil);
      }
    });
  }];
}
@end
