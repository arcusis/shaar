// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"

#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

@interface ARCShaarRuntime (PrivateHandles)
- (shaar_engine *)privateEngineHandle;
- (uint64_t)nextPrivateDevToolsRequestID;
- (shaar_profile *)privateProfileHandleForID:(NSString *)profileID;
- (BOOL)privateIdentityOccupied:(NSString *)identity;
- (BOOL)isPrivateIdentity:(NSString *)identity;
- (BOOL)privateTabOwned:(NSString *)tabID windowID:(NSString *)windowID
             contextID:(NSString *)contextID;
- (void)receivePrivateEvent:(const shaar_event *)event payload:(NSDictionary *)payload;
- (void)preparePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID url:(NSString *)url;
- (void)revokePrivateCookiesForWindowID:(NSString *)windowID;
@end

NSMutableDictionary *ARCPrivateShaarState(ARCShaarRuntime *runtime);
shaar_bytes ARCPrivateShaarBytes(NSString *value);
shaar_error ARCPrivateShaarEmptyError(void);
BOOL ARCPrivateShaarSubmit(ARCShaarRuntime *runtime, shaar_scope scope,
                           shaar_window *window, shaar_tab *tab,
                           shaar_operation operation, NSDictionary *payload,
                           void (^completion)(NSDictionary *reply),
                           uint64_t *requestIDOut = nullptr);
BOOL ARCPrivateShaarInstallTrackerRules(shaar_private_session *session);
