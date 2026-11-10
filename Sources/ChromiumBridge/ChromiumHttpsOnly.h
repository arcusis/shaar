// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NS_ASSUME_NONNULL_BEGIN

/// Lowercase profile id Chromium accepts, or nil when the id is not canonical.
FOUNDATION_EXPORT NSString * _Nullable ARCCanonicalProfileID(NSString *profileID);

/// Merges https_only_mode_enabled into Profile <id>/Preferences. Leaves an unreadable file in place.
FOUNDATION_EXPORT BOOL ARCWriteHttpsOnlyPreference(
  NSURL *userDataDirectory, NSString *profileID, BOOL enabled);

/// The stored boolean, or nil when the file is missing, unreadable, or has no boolean.
FOUNDATION_EXPORT NSNumber * _Nullable ARCReadHttpsOnlyPreference(
  NSURL *userDataDirectory, NSString *profileID);

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
