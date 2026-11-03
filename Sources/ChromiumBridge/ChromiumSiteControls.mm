// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"

static const NSTimeInterval ARCSiteControlTimeout = 10;

static BOOL ARCIsSiteOrigin(NSString *origin) {
  if (![origin isKindOfClass:NSString.class] || origin.length > 2048) return NO;
  NSURLComponents *components = [NSURLComponents componentsWithString:origin];
  NSString *scheme = components.scheme.lowercaseString;
  return ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) && components.host.length &&
    !components.user && !components.password && !components.query && !components.fragment &&
    (components.path.length == 0 || [components.path isEqualToString:@"/"]);
}

static NSError *ARCServiceFailure(NSDictionary *result, NSString *message) {
  return result[@"error"] || ![result[@"ok"] isEqual:@YES] ? ARCBridgeError(message) : nil;
}

@implementation ARCChromiumRuntime (SiteControls)

- (void)clearProfileSiteDataForProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  [_services call:@"browsing_data.clear" profileID:profileID args:@{@"types": @[@"siteData"]} completion:^(NSDictionary *result) {
    completion(ARCServiceFailure(result, @"Site data was not fully cleared."));
  }];
}

- (void)sitePermissionOriginsForProfileID:(NSString *)profileID
                             completion:(void (^)(NSArray<NSString *> *, NSError *))completion {
  [_services call:@"site_settings.origins" profileID:profileID args:@{} completion:^(NSDictionary *result) {
    NSArray *origins = result[@"origins"];
    if (result[@"error"] || ![origins isKindOfClass:NSArray.class]) {
      completion(nil, ARCBridgeError(@"Site permissions could not be read for this profile."));
      return;
    }
    for (id origin in origins) {
      if (!ARCIsSiteOrigin(origin)) {
        completion(nil, ARCBridgeError(@"Site permissions could not be read for this profile."));
        return;
      }
    }
    completion(origins, nil);
  }];
}

- (void)resetSitePermissionsForOrigin:(NSString *)origin profileID:(NSString *)profileID
                          completion:(void (^)(NSError *))completion {
  if (!ARCIsSiteOrigin(origin)) {
    completion(ARCBridgeError(@"Invalid site setting."));
    return;
  }
  [_services call:@"site_settings.reset" profileID:profileID args:@{@"origin": origin} completion:^(NSDictionary *result) {
    completion(ARCServiceFailure(result, @"The site setting was not saved."));
  }];
}

- (NSNumber *)thirdPartyCookiesBlockedForProfileID:(NSString *)profileID {
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!profile || profile.destroyed || profile.offTheRecord) return nil;
  return [profile boolPreference:@"profile.block_third_party_cookies"];
}

- (void)setThirdPartyCookiesBlocked:(BOOL)blocked profileID:(NSString *)profileID
                        completion:(void (^)(NSError *))completion {
  if (![self thirdPartyCookiesBlockedForProfileID:profileID]) {
    completion(ARCBridgeError(@"Third-party cookie controls are unavailable in this engine."));
    return;
  }
  [_profiles[profileID] setBoolPreference:@"profile.block_third_party_cookies" value:blocked];
  NSNumber *effective = [self thirdPartyCookiesBlockedForProfileID:profileID];
  completion(effective && effective.boolValue == blocked ? nil : ARCBridgeError(@"The cookie policy was not saved."));
}

- (void)deleteEngineProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  ArdiaCoreProfile *profile = _profiles[profileID];
  if (!ARCIsCanonicalID(profileID) || !profile || profile.destroyed || profile.offTheRecord ||
      [_deletingProfileIDs containsObject:profileID] || _privateProbeSourceLeases[profileID] ||
      [_privateProbePendingContexts.allValues containsObject:profileID]) {
    completion(ARCBridgeError(@"Close private windows before deleting this profile."));
    return;
  }
  if (!_deletingProfileIDs) _deletingProfileIDs = [NSMutableSet set];
  [_deletingProfileIDs addObject:profileID];
  for (NSString *tabID in [_owners.allKeys copy]) {
    if ([_owners[tabID] isEqualToString:profileID]) [self discardTabID:tabID];
  }
  [_extensionManagers[profileID] closeNow];
  [_extensionManagers removeObjectForKey:profileID];
  [_engine deleteProfile:profile completion:^(BOOL deleted) {
    if (!deleted) {
      [self->_deletingProfileIDs removeObject:profileID];
      completion(ARCBridgeError(@"The engine could not delete this profile."));
      return;
    }
    [self->_profiles removeObjectForKey:profileID];
    [self->_services unbindProfileID:profileID];
    completion(nil);
  }];
}

/// The selected tab when it belongs to `profileID`; site controls never act on background tabs.
- (ArdiaCoreTab *)siteControlTabForID:(NSString *)tabID profileID:(NSString *)profileID {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!tab || tab.closed || ![self isSelectedTabID:tabID] || ![_owners[tabID] isEqualToString:profileID]) return nil;
  return tab;
}

- (NSDictionary<NSString *, id> *)securityInfoForTabID:(NSString *)tabID profileID:(NSString *)profileID {
  return [self siteControlTabForID:tabID profileID:profileID].securityInfo;
}

- (void)siteSettingsForOrigin:(NSString *)origin profileID:(NSString *)profileID
                   completion:(void (^)(NSDictionary<NSString *, NSDictionary *> *, NSError *))completion {
  if (!ARCIsSiteOrigin(origin)) {
    completion(nil, ARCBridgeError(@"Site settings need a web address."));
    return;
  }
  [_services call:@"site_settings.get" profileID:profileID args:@{@"origin": origin} completion:^(NSDictionary *result) {
    NSDictionary *settings = result[@"settings"];
    if (result[@"error"] || ![settings isKindOfClass:NSDictionary.class]) {
      completion(nil, ARCBridgeError(@"Site settings could not be read for this profile."));
    } else {
      completion(settings, nil);
    }
  }];
}

- (void)setSiteSetting:(NSString *)type value:(NSString *)value origin:(NSString *)origin
             profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (!ARCIsSiteOrigin(origin) || ![type isKindOfClass:NSString.class] || type.length > 64 ||
      ![@[@"allow", @"block", @"ask", @"default"] containsObject:value]) {
    completion(ARCBridgeError(@"Invalid site setting."));
    return;
  }
  NSDictionary *args = @{@"origin": origin, @"type": type, @"value": value};
  [_services call:@"site_settings.set" profileID:profileID args:args completion:^(NSDictionary *result) {
    completion(ARCServiceFailure(result, @"The site setting was not saved."));
  }];
}

- (void)clearSiteDataForOrigin:(NSString *)origin profileID:(NSString *)profileID
                    completion:(void (^)(NSError *))completion {
  if (!ARCIsSiteOrigin(origin)) {
    completion(ARCBridgeError(@"Site data needs a web address."));
    return;
  }
  [_services call:@"site_data.clear" profileID:profileID args:@{@"origin": origin} completion:^(NSDictionary *result) {
    BOOL cleared = !result[@"error"] && [result[@"storage"] isEqual:@YES] && [result[@"cookies"] isKindOfClass:NSNumber.class];
    completion(cleared ? nil : ARCBridgeError(@"Site data was not fully cleared."));
  }];
}

- (void)clearCacheForProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  [_services call:@"browsing_data.clear" profileID:profileID args:@{@"types": @[@"cache"]} completion:^(NSDictionary *result) {
    completion(ARCServiceFailure(result, @"The cache was not cleared."));
  }];
}

- (void)clearCookiesForTabID:(NSString *)tabID profileID:(NSString *)profileID
                  completion:(void (^)(NSError *))completion {
  ArdiaCoreTab *tab = [self siteControlTabForID:tabID profileID:profileID];
  if (!tab || !ARCIsSiteOrigin(tab.securityInfo[@"origin"])) {
    completion(ARCBridgeError(@"Cookies can only be cleared for a web page."));
    return;
  }
  __weak ArdiaCoreTab *weakTab = tab;
  [tab devToolsCall:@"Network.getCookies" params:@{@"urls": @[tab.url]} timeout:ARCSiteControlTimeout
         completion:^(NSDictionary *result, NSString *error) {
    NSArray *cookies = result[@"cookies"];
    ArdiaCoreTab *owner = weakTab;
    if (error || !owner || ![cookies isKindOfClass:NSArray.class]) {
      completion(ARCBridgeError(@"Cookies could not be read for this page."));
      return;
    }
    [self deleteCookies:cookies inTab:owner completion:completion];
  }];
}

/// Deletes each cookie by its exact name, domain, path and partition, reporting once all finish.
- (void)deleteCookies:(NSArray *)cookies inTab:(ArdiaCoreTab *)tab completion:(void (^)(NSError *))completion {
  __block NSUInteger remaining = cookies.count;
  __block BOOL failed = NO;
  if (!remaining) {
    completion(nil);
    return;
  }
  for (id cookie in cookies) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    if ([cookie isKindOfClass:NSDictionary.class]) {
      for (NSString *key in @[@"name", @"domain", @"path", @"partitionKey"]) params[key] = cookie[key];
    }
    [tab devToolsCall:@"Network.deleteCookies" params:params timeout:ARCSiteControlTimeout
           completion:^(NSDictionary *result, NSString *error) {
      failed = failed || error != nil || ![params[@"name"] isKindOfClass:NSString.class];
      if (--remaining == 0) completion(failed ? ARCBridgeError(@"Some cookies were not cleared.") : nil);
    }];
  }
}

@end
