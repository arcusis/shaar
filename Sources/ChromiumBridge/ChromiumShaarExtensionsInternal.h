// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridge.h"
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

NS_ASSUME_NONNULL_BEGIN

// Access to the Shaar runtime's owned handles stays inside ChromiumShaarBackend.mm.
@interface ARCShaarRuntime (ExtensionHandles)
- (BOOL)shaarSubmitExtensionOperation:(shaar_operation)operation
                           profileID:(NSString *)profileID
                               tabID:(NSString * _Nullable)tabID
                  allowsProfileOnly:(BOOL)allowsProfileOnly
                             payload:(NSDictionary *)payload
                          completion:(void (^)(NSString * _Nullable json, shaar_error_code code))completion;
- (BOOL)shaarOwnsSelectedTabID:(NSString *)tabID profileID:(NSString *)profileID;
- (nullable NSString *)shaarProfileIDForTabID:(NSString *)tabID;
- (nullable NSString *)shaarWindowIDForTabID:(NSString *)tabID;
- (nullable NSString *)shaarProfileIDForWindowID:(NSString *)windowID;
- (nullable NSURL *)shaarProfileDirectoryForID:(NSString *)profileID;
- (nullable NSView *)shaarExtensionPopupViewForID:(NSString *)popupID
                                         windowID:(NSString *)windowID;
- (void)shaarExtensionEvent:(const shaar_event *)event payload:(NSDictionary *)payload;
@end

NS_ASSUME_NONNULL_END
