// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridgeVerification.h"

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
