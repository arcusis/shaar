// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumProbeRoot.h"
#import "include/ChromiumBridgeVerification.h"
#include <fcntl.h>
#include <cstring>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>

BOOL ARCProbeRootIsOwned(NSURL *root) {
  if (!root.isFileURL) return NO;
  NSURL *canonical = root.URLByResolvingSymlinksInPath.URLByStandardizingPath;
  NSURL *temporary = [NSURL fileURLWithPath:NSTemporaryDirectory()].URLByResolvingSymlinksInPath.URLByStandardizingPath;
  struct stat info;
  BOOL valid = [canonical.URLByDeletingLastPathComponent.path isEqualToString:temporary.path] &&
    [canonical.lastPathComponent hasPrefix:@"arcusis-engine-probe-"] &&
    [root.URLByResolvingSymlinksInPath.URLByStandardizingPath.path isEqualToString:canonical.path] &&
    lstat(root.path.stringByStandardizingPath.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) &&
    info.st_uid == getuid() && (info.st_mode & 07777) == 0700;
  if (!valid) return NO;
  NSURL *marker = [canonical URLByAppendingPathComponent:@".arcusis-probe"];
  int fd = open(marker.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
  static const char expected[] = "arcusis-engine-probe-v1\n";
  char contents[sizeof(expected)] = {};
  valid = fd >= 0 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
    info.st_uid == getuid() && info.st_nlink == 1 && (info.st_mode & 07777) == 0600 &&
    info.st_size == sizeof(expected) - 1 && read(fd, contents, sizeof(contents)) == sizeof(expected) - 1 &&
    memcmp(contents, expected, sizeof(expected) - 1) == 0;
  if (fd >= 0) close(fd);
  return valid;
}

NSDictionary *ARCProbeExternalAppLaunchAuditForTesting(NSString *url, NSArray *launches,
                                                        NSURL *root, BOOL enabled) {
  static const NSUInteger maximumEntries = 256;
  static const NSUInteger maximumURLLength = 4096;
  if (!enabled || !ARCProbeRootIsOwned(root) || ![url isKindOfClass:NSString.class] ||
      url.length == 0 || url.length > maximumURLLength || ![launches isKindOfClass:NSArray.class] ||
      launches.count > maximumEntries) return nil;
  NSURLComponents *target = [NSURLComponents componentsWithString:url];
  if (!target || target.scheme.length == 0 || !target.URL) return nil;

  NSUInteger matchingCount = 0;
  BOOL allUnremembered = YES;
  for (id item in launches) {
    if (![item isKindOfClass:NSDictionary.class] || [item count] != 2) return nil;
    NSDictionary *entry = item;
    id launchURL = entry[@"url"];
    id remembered = entry[@"remembered"];
    if (![launchURL isKindOfClass:NSString.class] || [launchURL length] == 0 ||
        [launchURL length] > maximumURLLength || ![remembered isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)remembered) != CFBooleanGetTypeID()) return nil;
    NSURLComponents *parsed = [NSURLComponents componentsWithString:launchURL];
    if (!parsed || parsed.scheme.length == 0 || !parsed.URL) return nil;
    if ([launchURL isEqualToString:url]) {
      if (matchingCount == std::numeric_limits<NSUInteger>::max()) return nil;
      ++matchingCount;
    }
    if ([remembered boolValue]) allUnremembered = NO;
  }
  return @{@"count": @(launches.count), @"matchingCount": @(matchingCount),
           @"allUnremembered": @(allUnremembered)};
}
