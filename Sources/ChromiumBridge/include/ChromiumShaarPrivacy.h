// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Refreshes the selected regular profile's cookie policy from Shaar site-data.
@interface ARCShaarRuntime (PrivacySettings)
- (void)refreshThirdPartyCookiePolicyForProfileID:(NSString *)profileID
    completion:(void (NS_SWIFT_UI_ACTOR ^)(void))completion NS_SWIFT_UI_ACTOR;
- (nullable NSNumber *)thirdPartyCookiesManagedForProfileID:(NSString *)profileID;
@end

NS_ASSUME_NONNULL_END
