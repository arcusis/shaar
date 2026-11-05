// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarPrivateSupport.h"
#import <objc/runtime.h>
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

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
- (void)holdShaarPrivateInspectorTabID:(NSString *)tabID windowID:(NSString *)windowID
                           contextID:(NSString *)contextID lease:(NSString *)lease;
@end

@implementation ARCShaarRuntime (Inspector)
- (BOOL)beginInspectorForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                          contextID:(NSString *)contextID {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return NO;
  if (ShaarInspectorLeases(self)[tabID]) return YES;
  NSString *lease = NSUUID.UUID.UUIDString;
  ShaarInspectorLeases(self)[tabID] = lease;
  [self holdShaarPrivateInspectorTabID:tabID windowID:windowID contextID:contextID lease:lease];
  return YES;
}

- (void)holdShaarPrivateInspectorTabID:(NSString *)tabID windowID:(NSString *)windowID
                           contextID:(NSString *)contextID lease:(NSString *)lease {
  if (![ShaarInspectorLeases(self)[tabID] isEqual:lease]) return;
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) {
    [ShaarInspectorLeases(self) removeObjectForKey:tabID];
    return;
  }
  [self shaarPrivateDevToolsCall:@"Runtime.evaluate"
                         params:@{@"expression": @"new Promise(resolve => setTimeout(resolve, 30000))",
                                  @"awaitPromise": @YES}
                     capability:SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR tabID:tabID
                       windowID:windowID contextID:contextID
                     completion:^(NSDictionary *result, NSError *error) {}];
  __weak ARCShaarRuntime *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf holdShaarPrivateInspectorTabID:tabID windowID:windowID contextID:contextID lease:lease];
  });
}

- (void)privateInspectorCall:(NSString *)method params:(NSDictionary *)params tabID:(NSString *)tabID
                   windowID:(NSString *)windowID contextID:(NSString *)contextID
                 completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) {
    completion(nil, ARCBridgeError(@"The Inspector target is no longer available."));
    return;
  }
  __weak ARCShaarRuntime *weakSelf = self;
  [self shaarPrivateDevToolsCall:method params:params capability:SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR
                         tabID:tabID windowID:windowID contextID:contextID
                     completion:^(NSDictionary *result, NSError *error) {
    if (![weakSelf privateTabOwned:tabID windowID:windowID contextID:contextID]) {
      completion(nil, ARCBridgeError(@"The Inspector target changed."));
      return;
    }
    completion(result, error);
  }];
}

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
