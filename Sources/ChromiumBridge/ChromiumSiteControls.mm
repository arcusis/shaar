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
