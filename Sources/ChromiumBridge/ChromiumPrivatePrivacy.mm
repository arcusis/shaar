// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"

static NSString *ARCPrivateOrigin(NSString *url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:url];
  if (![@[@"https", @"http"] containsObject:parts.scheme.lowercaseString] || !parts.host.length ||
      parts.user.length || parts.password.length) return nil;
  parts.path = @"";
  parts.query = nil;
  parts.fragment = nil;
  return parts.string;
}

@implementation ARCChromiumRuntime (PrivatePrivacy)

- (BOOL)privateOriginAllowed:(NSString *)origin contextID:(NSString *)contextID {
  ArdiaCoreProfile *profile = _privateProbeContexts[contextID][@"profile"];
  for (NSDictionary *window in _privateProbeWindows.allValues) {
    if (_privateProbeContexts[window[@"contextID"]][@"profile"] == profile &&
        [window[@"cookieOrigins"] containsObject:origin]) return YES;
  }
  return NO;
}

- (void)configurePrivateTab:(ArdiaCoreTab *)tab tabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID url:(NSString *)url {
  NSMutableDictionary *entry = (NSMutableDictionary *)_privateProbeTabs[tabID];
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil]) return;
  NSString *origin = ARCPrivateOrigin(url);
  __block BOOL settingsOK = YES;
  if (origin) {
    for (NSString *type in @[@"camera", @"microphone", @"location", @"notifications", @"cookies"]) {
      NSString *value = [type isEqual:@"cookies"] && [self privateOriginAllowed:origin contextID:contextID]
        ? @"allow" : @"block";
      // The pinned C service replies synchronously on the UI thread and accepts an
      // explicit OTR selector. Never bind the OTR path as a regular service profile.
      [_services call:@"site_settings.set" profileID:_privateProbeContexts[contextID][@"sourceProfileID"]
        args:@{@"offTheRecord": @YES, @"origin": origin, @"type": type, @"value": value}
        completion:^(NSDictionary *reply) {
        settingsOK = settingsOK && [reply[@"ok"] isEqual:@YES] && !reply[@"error"];
      }];
    }
  }
  if (!settingsOK) {
    entry[@"privacyError"] = @"Private site protections could not be applied.";
    if (self.onPrivateNavigationFailed)
      self.onPrivateNavigationFailed(contextID, windowID, tabID, entry[@"privacyError"]);
    return;
  }
  if (_privateProbeTabs[tabID] != entry ||
      ![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil]) return;
  entry[@"privacyError"] = nil;
  entry[@"privacyReady"] = @YES;
  [tab loadURL:url];
}

- (void)privateCookiesForTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID origin:(NSString *)origin
                  completion:(void (^)(NSNumber *, NSError *))completion {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] ||
      ![_privateProbeWindows[windowID][@"selectedTabID"] isEqual:tabID] || ![ARCPrivateOrigin(tab.url) isEqualToString:origin]) {
    completion(nil, ARCBridgeError(@"Select a private web page to change cookies."));
    return;
  }
  NSDictionary *context = _privateProbeContexts[contextID];
  [_services call:@"site_settings.get" profileID:context[@"sourceProfileID"]
    args:@{@"offTheRecord": @YES, @"origin": origin} completion:^(NSDictionary *reply) {
    NSString *value = reply[@"settings"][@"cookies"][@"value"];
    if (self->_privateProbeContexts[contextID] != context ||
        ![ARCPrivateOrigin(tab.url) isEqualToString:origin] ||
        ![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil] ||
        ![self->_privateProbeWindows[windowID][@"selectedTabID"] isEqual:tabID] ||
        ![@[@"allow", @"block"] containsObject:value] || reply[@"error"]) {
      completion(nil, ARCBridgeError(@"The private cookie setting could not be read."));
    } else {
      completion(@([value isEqualToString:@"allow"]), nil);
    }
  }];
}

- (void)setPrivateCookiesAllowed:(BOOL)allowed tabID:(NSString *)tabID windowID:(NSString *)windowID
                      contextID:(NSString *)contextID origin:(NSString *)origin completion:(void (^)(NSError *))completion {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] ||
      ![_privateProbeWindows[windowID][@"selectedTabID"] isEqual:tabID] || ![ARCPrivateOrigin(tab.url) isEqualToString:origin]) {
    completion(ARCBridgeError(@"The private site control target is no longer selected."));
    return;
  }
  NSDictionary *context = _privateProbeContexts[contextID];
  NSDictionary *window = _privateProbeWindows[windowID];
  [_services call:@"site_settings.set" profileID:context[@"sourceProfileID"]
    args:@{@"offTheRecord": @YES, @"origin": origin, @"type": @"cookies", @"value": allowed ? @"allow" : @"block"}
    completion:^(NSDictionary *reply) {
    if (self->_privateProbeContexts[contextID] != context || self->_privateProbeWindows[windowID] != window ||
        ![reply[@"ok"] isEqual:@YES] || reply[@"error"]) {
      completion(ARCBridgeError(@"The private cookie setting was not applied."));
      return;
    }
    // All windows share Chromium's primary OTR profile. Revoking a grant revokes it everywhere.
    for (NSMutableDictionary *other in self->_privateProbeWindows.allValues) {
      if (self->_privateProbeContexts[other[@"contextID"]][@"profile"] == context[@"profile"])
        [other[@"cookieOrigins"] removeObject:origin];
    }
    if (allowed) {
      NSMutableDictionary *owner = self->_privateProbeWindows[windowID];
      if (!owner[@"cookieOrigins"]) owner[@"cookieOrigins"] = [NSMutableSet set];
      [owner[@"cookieOrigins"] addObject:origin];
    }
    completion(nil);
  }];
}

@end
