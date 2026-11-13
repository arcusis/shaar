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

/// Choice to persist before a profile opens. `chosen` is this process's stored
/// value, or nil when the load was not given one. An existing Preferences
/// boolean is left unchanged in that case. A profile with no choice yet is
/// seeded on. Returns the applied boolean, or nil when the id or file is unusable.
FOUNDATION_EXPORT NSNumber * _Nullable ARCSeedHttpsOnlyPreference(
    NSURL *userDataDirectory, NSString *profileID, NSNumber * _Nullable chosen);

/// Commits the cached HTTPS-only choice only after required persistence and live apply succeed.
/// If persistence succeeds but live apply fails, records the disk value as dirty so a retry of
/// the cached value rewrites Preferences.
FOUNDATION_EXPORT BOOL ARCCommitHttpsOnlyModeChange(
    NSMutableDictionary<NSString *, NSNumber *> *cache,
    NSMutableSet<NSString *> *dirtyProfiles,
    NSString *profileID,
    BOOL enabled,
    BOOL hasLoadedProfile,
    BOOL (^writePreference)(BOOL),
    BOOL (^applyLive)(BOOL));

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif
