// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumHttpsOnly.h"

static NSString *const ARCHttpsOnlyPreferenceKey = @"https_only_mode_enabled";

NSString *ARCCanonicalProfileID(NSString *profileID) {
  if (profileID.length != 36) return nil;
  NSString *lowercase = profileID.lowercaseString;
  for (NSUInteger index = 0; index < 36; index++) {
    unichar character = [lowercase characterAtIndex:index];
    BOOL hyphenSlot = index == 8 || index == 13 || index == 18 || index == 23;
    if (hyphenSlot) {
      if (character != '-') return nil;
      continue;
    }
    BOOL hex = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
    if (!hex) return nil;
  }
  return lowercase;
}

static NSMutableDictionary *ARCReadJSONObject(NSURL *url, BOOL *readable) {
  NSData *data = [NSData dataWithContentsOfURL:url];
  *readable = YES;
  if (!data) return [NSMutableDictionary dictionary];
  id object = [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingMutableContainers error:nil];
  if ([object isKindOfClass:NSMutableDictionary.class]) return object;
  *readable = NO;
  return nil;
}

static BOOL ARCWriteJSONObject(NSDictionary *object, NSURL *directory, NSURL *file) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
  NSFileManager *files = NSFileManager.defaultManager;
  NSDictionary *owner = @{NSFilePosixPermissions: @0700};
  if (!json || ![files createDirectoryAtURL:directory withIntermediateDirectories:YES
                                 attributes:owner error:nil] ||
      ![json writeToURL:file options:NSDataWritingAtomic error:nil]) return NO;
  return [files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:file.path error:nil];
}

BOOL ARCWriteHttpsOnlyPreference(NSURL *userDataDirectory, NSString *profileID, BOOL enabled) {
  NSString *canonical = ARCCanonicalProfileID(profileID);
  if (!canonical || !userDataDirectory.isFileURL) return NO;
  NSURL *directory = [userDataDirectory URLByAppendingPathComponent:
                      [@"Profile " stringByAppendingString:canonical] isDirectory:YES];
  NSURL *file = [directory URLByAppendingPathComponent:@"Preferences"];
  BOOL readable = NO;
  NSMutableDictionary *state = ARCReadJSONObject(file, &readable);
  if (!readable) return NO;
  NSNumber *value = @(enabled);
  if ([state[ARCHttpsOnlyPreferenceKey] isEqual:value]) return YES;
  state[ARCHttpsOnlyPreferenceKey] = value;
  return ARCWriteJSONObject(state, directory, file);
}

NSNumber *ARCReadHttpsOnlyPreference(NSURL *userDataDirectory, NSString *profileID) {
  NSString *canonical = ARCCanonicalProfileID(profileID);
  if (!canonical || !userDataDirectory.isFileURL) return nil;
  NSURL *directory = [userDataDirectory URLByAppendingPathComponent:
                      [@"Profile " stringByAppendingString:canonical] isDirectory:YES];
  NSURL *file = [directory URLByAppendingPathComponent:@"Preferences"];
  BOOL readable = NO;
  NSDictionary *state = ARCReadJSONObject(file, &readable);
  if (!readable) return nil;
  id value = state[ARCHttpsOnlyPreferenceKey];
  return [value isKindOfClass:NSNumber.class] ? value : nil;
}

NSNumber *ARCSeedHttpsOnlyPreference(
    NSURL *userDataDirectory, NSString *profileID, NSNumber *chosen) {
  NSString *canonical = ARCCanonicalProfileID(profileID);
  if (!canonical || !userDataDirectory.isFileURL) return nil;
  if (chosen) {
    if (!ARCWriteHttpsOnlyPreference(userDataDirectory, canonical, chosen.boolValue)) return nil;
    return @(chosen.boolValue);
  }
  NSNumber *existing = ARCReadHttpsOnlyPreference(userDataDirectory, canonical);
  if (existing) return existing;
  if (!ARCWriteHttpsOnlyPreference(userDataDirectory, canonical, YES)) return nil;
  return @YES;
}

BOOL ARCCommitHttpsOnlyModeChange(
    NSMutableDictionary<NSString *, NSNumber *> *cache,
    NSMutableSet<NSString *> *dirtyProfiles,
    NSString *profileID,
    BOOL enabled,
    BOOL hasLoadedProfile,
    BOOL (^writePreference)(BOOL),
    BOOL (^applyLive)(BOOL)) {
  NSNumber *previous = cache[profileID];
  BOOL changed = !previous || previous.boolValue != enabled;
  BOOL needsWrite = changed || [dirtyProfiles containsObject:profileID];
  if (needsWrite && !writePreference(enabled)) return NO;
  if (hasLoadedProfile && changed && !applyLive(enabled)) {
    [dirtyProfiles addObject:profileID];
    return NO;
  }
  [dirtyProfiles removeObject:profileID];
  cache[profileID] = @(enabled);
  return YES;
}
