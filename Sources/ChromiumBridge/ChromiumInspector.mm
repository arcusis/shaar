// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import <objc/runtime.h>
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

@implementation ARCChromiumRuntime (Inspector)
- (BOOL)beginInspectorForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab || ![_owners[tabID] isEqual:profileID] || ![_tabWindows[tabID] isEqual:windowID]) return NO;
  if (!_inspectorLeases) _inspectorLeases = [NSMutableDictionary dictionary];
  if (_inspectorLeases[tabID]) return YES;
  NSString *lease = NSUUID.UUID.UUIDString;
  _inspectorLeases[tabID] = lease;
  [self holdInspectorTab:tab identity:tabID lease:lease];
  return YES;
}

- (void)holdInspectorTab:(ArdiaCoreTab *)tab identity:(NSString *)identity lease:(NSString *)lease {
  if (![_inspectorLeases[identity] isEqual:lease]) return;
  if ([self liveTabForID:identity] != tab) { [_inspectorLeases removeObjectForKey:identity]; return; }
  // The pinned bridge detaches idle clients, losing DOM/CSS identifiers. Overlapping,
  // bounded calls retain this session without a debugging socket or event subscription.
  [tab devToolsCall:@"Runtime.evaluate"
            params:@{@"expression": @"new Promise(resolve => setTimeout(resolve, 30000))", @"awaitPromise": @YES}
           timeout:35 completion:^(NSDictionary *result, NSString *error) {}];
  __weak ARCChromiumRuntime *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf holdInspectorTab:tab identity:identity lease:lease];
  });
}

- (void)endInspectorForTabID:(NSString *)tabID { [_inspectorLeases removeObjectForKey:tabID]; }

- (void)inspectorCall:(NSString *)method params:(NSDictionary *)params tabID:(NSString *)tabID
           profileID:(NSString *)profileID windowID:(NSString *)windowID
          completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  static NSSet *methods;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    methods = [NSSet setWithArray:@[@"Runtime.evaluate", @"Runtime.releaseObject", @"Runtime.getProperties",
      @"Runtime.releaseObjectGroup", @"DOM.enable",
      @"DOM.getDocument", @"DOM.requestNode", @"DOM.getBoxModel", @"CSS.enable",
      @"CSS.getPlatformFontsForNode", @"CSS.getBackgroundColors", @"CSS.getMatchedStylesForNode",
      @"CSS.getComputedStyleForNode", @"CSS.getStyleSheetText", @"Page.enable", @"Page.getResourceTree",
      @"Page.getResourceContent", @"Page.captureScreenshot", @"Overlay.enable", @"Overlay.disable",
      @"Overlay.setShowGridOverlays", @"Overlay.setShowFlexOverlays", @"Overlay.getGridHighlightObjectsForTest",
      @"DOM.describeNode", @"Accessibility.getPartialAXTree"]];
  });
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab || ![_owners[tabID] isEqual:profileID] || ![_tabWindows[tabID] isEqual:windowID] ||
      ![methods containsObject:method]) {
    completion(nil, ARCBridgeError(@"The Inspector target is no longer available."));
    return;
  }
  [tab devToolsCall:method params:params timeout:10 completion:^(NSDictionary *result, NSString *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([self liveTabForID:tabID] != tab || ![self->_owners[tabID] isEqual:profileID] ||
          ![self->_tabWindows[tabID] isEqual:windowID]) {
        completion(nil, ARCBridgeError(@"The Inspector target changed."));
      } else if (error || result[@"error"]) {
        completion(nil, ARCBridgeError(error ?: [result[@"error"] description]));
      } else {
        completion(result ?: @{}, nil);
      }
    });
  }];
}
@end

namespace {
char kShaarInspectorLeases;
NSMutableDictionary<NSString *, NSString *> *ShaarInspectorLeases(ARCShaarRuntime *runtime) {
  NSMutableDictionary *leases = objc_getAssociatedObject(runtime, &kShaarInspectorLeases);
  if (!leases) {
    leases = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, &kShaarInspectorLeases, leases, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return leases;
}
}

@interface ARCShaarRuntime (InspectorLease)
- (void)holdShaarInspectorTabID:(NSString *)tabID profileID:(NSString *)profileID
                      windowID:(NSString *)windowID lease:(NSString *)lease;
@end

@implementation ARCShaarRuntime (Inspector)
- (BOOL)beginInspectorForTabID:(NSString *)tabID profileID:(NSString *)profileID windowID:(NSString *)windowID {
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) return NO;
  NSMutableDictionary *leases = ShaarInspectorLeases(self);
  if (leases[tabID]) return YES;
  NSString *lease = NSUUID.UUID.UUIDString;
  leases[tabID] = lease;
  [self holdShaarInspectorTabID:tabID profileID:profileID windowID:windowID lease:lease];
  return YES;
}

- (void)holdShaarInspectorTabID:(NSString *)tabID profileID:(NSString *)profileID
                      windowID:(NSString *)windowID lease:(NSString *)lease {
  if (![ShaarInspectorLeases(self)[tabID] isEqual:lease]) return;
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    [ShaarInspectorLeases(self) removeObjectForKey:tabID];
    return;
  }
  [self shaarDevToolsCall:@"Runtime.evaluate"
                  params:@{@"expression": @"new Promise(resolve => setTimeout(resolve, 30000))",
                           @"awaitPromise": @YES}
              capability:SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR tabID:tabID
               profileID:profileID windowID:windowID completion:^(NSDictionary *result, NSError *error) {}];
  __weak ARCShaarRuntime *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf holdShaarInspectorTabID:tabID profileID:profileID windowID:windowID lease:lease];
  });
}

- (void)endInspectorForTabID:(NSString *)tabID {
  [ShaarInspectorLeases(self) removeObjectForKey:tabID];
}

- (void)inspectorCall:(NSString *)method params:(NSDictionary *)params tabID:(NSString *)tabID
           profileID:(NSString *)profileID windowID:(NSString *)windowID
          completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    completion(nil, ARCBridgeError(@"The Inspector target is no longer available."));
    return;
  }
  __weak ARCShaarRuntime *weakSelf = self;
  [self shaarDevToolsCall:method params:params capability:SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR
                   tabID:tabID profileID:profileID windowID:windowID
              completion:^(NSDictionary *result, NSError *error) {
    if (![weakSelf shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
      completion(nil, ARCBridgeError(@"The Inspector target changed."));
      return;
    }
    completion(result, error);
  }];
}
@end
