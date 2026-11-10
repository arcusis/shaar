// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumLocalState.h"

// Chromium's local-state preference that lets extensions with the "background" permission keep
// the browser running after its windows close. Chromium 155 has no switch for it.
static NSString *const ARCBackgroundModeKey = @"background_mode";
static NSString *const ARCBackgroundModeEnabledKey = @"enabled";

static NSMutableDictionary *ARCReadLocalState(NSURL *url, BOOL *readable) {
  NSData *data = [NSData dataWithContentsOfURL:url];
  *readable = YES;
  if (!data) return [NSMutableDictionary dictionary];
  id state = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers
                                               error:nil];
  if ([state isKindOfClass:NSMutableDictionary.class]) return state;
  *readable = NO;
  return nil;
}

static BOOL ARCBackgroundModeIsOff(NSDictionary *state) {
  id mode = state[ARCBackgroundModeKey];
  return [mode isKindOfClass:NSDictionary.class] &&
    [mode[ARCBackgroundModeEnabledKey] isEqual:@NO];
}

BOOL ARCDisableBackgroundMode(NSURL *userDataDirectory) {
  NSURL *url = [userDataDirectory URLByAppendingPathComponent:@"Local State"];
  BOOL readable = NO;
  NSMutableDictionary *state = ARCReadLocalState(url, &readable);
  // Chromium recovers an unreadable file itself; never replace it with a partial one.
  if (!readable) return NO;
  if (ARCBackgroundModeIsOff(state)) return YES;
  NSMutableDictionary *mode = [NSMutableDictionary dictionary];
  if ([state[ARCBackgroundModeKey] isKindOfClass:NSDictionary.class]) {
    [mode addEntriesFromDictionary:state[ARCBackgroundModeKey]];
  }
  mode[ARCBackgroundModeEnabledKey] = @NO;
  state[ARCBackgroundModeKey] = mode;
  NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  NSFileManager *files = NSFileManager.defaultManager;
  NSDictionary *owner = @{NSFilePosixPermissions: @0700};
  if (!json || ![files createDirectoryAtURL:userDataDirectory withIntermediateDirectories:YES
                                 attributes:owner error:nil] ||
      ![json writeToURL:url options:NSDataWritingAtomic error:nil]) return NO;
  return [files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:url.path error:nil];
}

// Chromium 157 shows a tab-modal dialog instead of the HTTPS-only interstitial when this
// labs flag is enabled. Shaar has no dialog host, so force the disabled choice.
static NSString *const ARCHttpsFirstDialogFlag = @"https-first-dialog-ui@2";
static NSString *const ARCHttpsFirstDialogPrefix = @"https-first-dialog-ui@";

static BOOL ARCHttpsFirstDialogIsDisabled(NSArray *experiments) {
  BOOL disabled = NO;
  for (id entry in experiments) {
    if (![entry isKindOfClass:NSString.class]) continue;
    if (![entry hasPrefix:ARCHttpsFirstDialogPrefix]) continue;
    if (![entry isEqualToString:ARCHttpsFirstDialogFlag]) return NO;
    disabled = YES;
  }
  return disabled;
}

BOOL ARCDisableHttpsFirstDialog(NSURL *userDataDirectory) {
  NSURL *url = [userDataDirectory URLByAppendingPathComponent:@"Local State"];
  BOOL readable = NO;
  NSMutableDictionary *state = ARCReadLocalState(url, &readable);
  if (!readable) return NO;
  id browserValue = state[@"browser"];
  NSMutableDictionary *browser = nil;
  if (!browserValue) {
    browser = [NSMutableDictionary dictionary];
  } else if ([browserValue isKindOfClass:NSMutableDictionary.class]) {
    browser = browserValue;
  } else if ([browserValue isKindOfClass:NSDictionary.class]) {
    browser = [browserValue mutableCopy];
  } else {
    return NO;
  }
  id experimentsValue = browser[@"enabled_labs_experiments"];
  NSMutableArray *experiments = nil;
  if (!experimentsValue) {
    experiments = [NSMutableArray array];
  } else if ([experimentsValue isKindOfClass:NSMutableArray.class]) {
    experiments = experimentsValue;
  } else if ([experimentsValue isKindOfClass:NSArray.class]) {
    experiments = [experimentsValue mutableCopy];
  } else {
    return NO;
  }
  if (ARCHttpsFirstDialogIsDisabled(experiments)) return YES;
  NSMutableArray *kept = [NSMutableArray array];
  for (id entry in experiments) {
    if ([entry isKindOfClass:NSString.class] && [entry hasPrefix:ARCHttpsFirstDialogPrefix]) continue;
    [kept addObject:entry];
  }
  [kept addObject:ARCHttpsFirstDialogFlag];
  browser[@"enabled_labs_experiments"] = kept;
  state[@"browser"] = browser;
  NSData *json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  NSFileManager *files = NSFileManager.defaultManager;
  NSDictionary *owner = @{NSFilePosixPermissions: @0700};
  if (!json || ![files createDirectoryAtURL:userDataDirectory withIntermediateDirectories:YES
                                 attributes:owner error:nil] ||
      ![json writeToURL:url options:NSDataWritingAtomic error:nil]) return NO;
  return [files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:url.path error:nil];
}
