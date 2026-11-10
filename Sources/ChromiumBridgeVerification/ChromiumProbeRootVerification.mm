// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumProbeRoot.h"
#import "include/ChromiumBridgeVerification.h"
#include <cstring>
#include <limits>

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
