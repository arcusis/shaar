// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarPrivateSupport.h"
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

@implementation ARCShaarRuntime (Inspector)
- (BOOL)beginInspectorForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                          contextID:(NSString *)contextID {
  // Native owns a persistent target-bound CDP session. An awaited keepalive
  // would block its serialized command queue and delay pick/read/stop requests.
  return [self privateTabOwned:tabID windowID:windowID contextID:contextID];
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
  return [self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID];
}

- (void)endInspectorForTabID:(NSString *)tabID {
  // The page script removes its listeners and overlay. Native releases the
  // shared target session when the tab closes; no asynchronous hold is needed.
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
