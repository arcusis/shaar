// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

@implementation ARCShaarRuntime (DeveloperMode)
- (BOOL)beginDeveloperSessionForTabID:(NSString *)tabID profileID:(NSString *)profileID
                              windowID:(NSString *)windowID {
  // Native owns the persistent target session. Do not enqueue timer promises:
  // they block the same serialized CDP queue used by Inspector page tools.
  return [self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID];
}

- (void)endDeveloperSessionForTabID:(NSString *)tabID profileID:(NSString *)profileID
                            windowID:(NSString *)windowID {
  // Native releases its target-bound session when the tab closes.
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
