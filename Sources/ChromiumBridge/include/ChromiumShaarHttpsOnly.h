// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Regular-profile HTTPS-only choice. The current engine honors it the next time the profile opens.
@interface ARCShaarRuntime (HttpsOnly)
/// Stores the choice and writes Profile Preferences when the data directory is known.
/// YES when this process applies the choice to the next navigation.
- (BOOL)setHttpsOnlyModeEnabled:(BOOL)enabled forProfileID:(NSString *)profileID;
@end

NS_ASSUME_NONNULL_END
