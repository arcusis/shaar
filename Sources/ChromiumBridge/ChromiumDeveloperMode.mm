// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import <objc/runtime.h>
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

namespace {
char kShaarDeveloperLeases;
NSMutableDictionary<NSString *, NSDictionary *> *ShaarDeveloperLeases(ARCShaarRuntime *runtime) {
  NSMutableDictionary *leases = objc_getAssociatedObject(runtime, &kShaarDeveloperLeases);
  if (!leases) {
    leases = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, &kShaarDeveloperLeases, leases, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return leases;
}
}

@interface ARCShaarRuntime (DeveloperLease)
- (void)holdShaarDeveloperTabID:(NSString *)tabID profileID:(NSString *)profileID
                      windowID:(NSString *)windowID lease:(NSString *)lease;
@end

@implementation ARCShaarRuntime (DeveloperMode)
- (BOOL)beginDeveloperSessionForTabID:(NSString *)tabID profileID:(NSString *)profileID
                              windowID:(NSString *)windowID {
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) return NO;
  NSMutableDictionary *leases = ShaarDeveloperLeases(self);
  NSDictionary *current = leases[tabID];
  if ([current[@"profileID"] isEqual:profileID] && [current[@"windowID"] isEqual:windowID])
    return YES;
  NSString *lease = NSUUID.UUID.UUIDString;
  leases[tabID] = @{ @"profileID": profileID, @"windowID": windowID, @"lease": lease };
  [self holdShaarDeveloperTabID:tabID profileID:profileID windowID:windowID lease:lease];
  return YES;
}

- (void)holdShaarDeveloperTabID:(NSString *)tabID profileID:(NSString *)profileID
                      windowID:(NSString *)windowID lease:(NSString *)lease {
  if (![ShaarDeveloperLeases(self)[tabID][@"lease"] isEqual:lease]) return;
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    [ShaarDeveloperLeases(self) removeObjectForKey:tabID];
    return;
  }
  [self shaarDevToolsCall:@"Runtime.evaluate"
                  params:@{@"expression": @"new Promise(resolve => setTimeout(resolve, 30000))",
                           @"awaitPromise": @YES}
              capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
               profileID:profileID windowID:windowID completion:^(NSDictionary *result, NSError *error) {}];
  __weak ARCShaarRuntime *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf holdShaarDeveloperTabID:tabID profileID:profileID windowID:windowID lease:lease];
  });
}

- (void)endDeveloperSessionForTabID:(NSString *)tabID profileID:(NSString *)profileID
                            windowID:(NSString *)windowID {
  NSDictionary *lease = ShaarDeveloperLeases(self)[tabID];
  if ([lease[@"profileID"] isEqual:profileID] && [lease[@"windowID"] isEqual:windowID])
    [ShaarDeveloperLeases(self) removeObjectForKey:tabID];
}

- (void)developerCall:(NSString *)method params:(NSDictionary *)params tabID:(NSString *)tabID
           profileID:(NSString *)profileID windowID:(NSString *)windowID
          completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    completion(nil, ARCBridgeError(@"The developer tools target is no longer available."));
    return;
  }
  __weak ARCShaarRuntime *weakSelf = self;
  [self shaarDevToolsCall:method params:params capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER
                   tabID:tabID profileID:profileID windowID:windowID
              completion:^(NSDictionary *result, NSError *error) {
    if (![weakSelf shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
      completion(nil, ARCBridgeError(@"The developer tools target changed."));
      return;
    }
    completion(result, error);
  }];
}
@end
