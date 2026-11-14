// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Feature operations share the Shaar runtime's live ABI handles. This header is
// internal to ChromiumBridge and is never exposed to Swift.
#import "include/ChromiumBridge.h"
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

@interface ARCShaarRuntime (FeatureTransport)
- (BOOL)shaarHasProfileID:(NSString *)profileID;
- (NSString *)shaarProfileIDForTabID:(NSString *)tabID;
- (NSString *)shaarProfileIDForNativeID:(NSString *)nativeID;
- (BOOL)shaarHasTabID:(NSString *)tabID profileID:(NSString *)profileID selected:(BOOL)selected;
- (BOOL)shaarSubmit:(shaar_operation)operation profileID:(NSString *)profileID
              tabID:(NSString *)tabID payload:(NSDictionary *)payload
         completion:(void (^)(NSDictionary *result, NSError *error))completion;
- (BOOL)shaarDeleteProfileID:(NSString *)profileID;
- (BOOL)shaarDeleteProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion;
- (nullable NSURL *)shaarProfileDirectoryForID:(NSString *)profileID;
- (NSWindow *)shaarPictureInPictureWindowForTabID:(NSString *)tabID;
- (NSDictionary *)shaarSecurityInfoForTabID:(NSString *)tabID profileID:(NSString *)profileID;
@end

@interface ARCShaarRuntime (SiteControlsFeature)
- (void)shaarPrimeSiteControlsForProfileID:(NSString *)profileID completion:(void (^)(void))completion;
@end

@interface ARCShaarRuntime (EngineServicesFeature)
- (void)shaarPrimeEngineServicesForProfileID:(NSString *)profileID completion:(void (^)(void))completion;
- (void)shaarReceiveDownloadEventForProfileID:(NSString *)profileID payload:(NSDictionary *)payload;
@end
