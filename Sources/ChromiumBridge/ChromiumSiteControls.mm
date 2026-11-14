// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarFeatureTransport.h"
#import <objc/runtime.h>

static const NSTimeInterval ARCSiteControlTimeout = 10;
static constexpr shaar_operation ARCSiteCookieItems = static_cast<shaar_operation>(709);
static constexpr shaar_operation ARCSiteCookieSet = static_cast<shaar_operation>(710);
static constexpr shaar_operation ARCSiteCookieDelete = static_cast<shaar_operation>(711);

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

static BOOL ARCIsSelectedCookieScope(ARCShaarRuntime *runtime, NSString *tabID,
                                     NSString *profileID, NSString *origin) {
  if (!ARCIsSiteOrigin(origin) ||
      ![runtime shaarHasTabID:tabID profileID:profileID selected:YES]) return NO;
  NSDictionary *security = [runtime shaarSecurityInfoForTabID:tabID profileID:profileID];
  return [security[@"origin"] isEqualToString:origin];
}

static const void *ShaarCookiePolicyCacheKey = &ShaarCookiePolicyCacheKey;

static NSMutableDictionary<NSString *, NSNumber *> *ShaarCookiePolicyCache(ARCShaarRuntime *runtime) {
  NSMutableDictionary *cache = objc_getAssociatedObject(runtime, ShaarCookiePolicyCacheKey);
  if (!cache) {
    cache = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, ShaarCookiePolicyCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return cache;
}

static const void *ShaarManagedCookiePolicyCacheKey = &ShaarManagedCookiePolicyCacheKey;

static NSMutableDictionary<NSString *, NSNumber *> *ShaarManagedCookiePolicyCache(ARCShaarRuntime *runtime) {
  NSMutableDictionary *cache = objc_getAssociatedObject(runtime, ShaarManagedCookiePolicyCacheKey);
  if (!cache) {
    cache = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, ShaarManagedCookiePolicyCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return cache;
}

@implementation ARCShaarRuntime (SiteControls)

- (void)shaarPrimeSiteControlsForProfileID:(NSString *)profileID completion:(void (^)(void))completion {
  [self refreshThirdPartyCookiePolicyForProfileID:profileID completion:completion];
}

- (void)refreshThirdPartyCookiePolicyForProfileID:(NSString *)profileID completion:(void (^)(void))completion {
  [self shaarSubmit:SHAAR_OP_THIRD_PARTY_COOKIES_GET profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1} completion:^(NSDictionary *result, NSError *error) {
    NSNumber *blocked = result[@"blocked"];
    NSNumber *managed = result[@"managed"];
    if (!error && [blocked isKindOfClass:NSNumber.class] && [managed isKindOfClass:NSNumber.class]) {
      ShaarCookiePolicyCache(self)[profileID] = blocked;
      ShaarManagedCookiePolicyCache(self)[profileID] = managed;
    } else {
      [ShaarCookiePolicyCache(self) removeObjectForKey:profileID];
      [ShaarManagedCookiePolicyCache(self) removeObjectForKey:profileID];
    }
    completion();
  }];
}

- (void)clearProfileSiteDataForProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  [self shaarSubmit:SHAAR_OP_BROWSING_DATA_CLEAR profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"types": @[@"siteData"]}
        completion:^(NSDictionary *result, NSError *error) {
    completion(error ?: ([result[@"complete"] isEqual:@YES] ? nil : ARCBridgeError(@"Site data was not fully cleared.")));
  }];
}

- (void)sitePermissionOriginsForProfileID:(NSString *)profileID
                              completion:(void (^)(NSArray<NSString *> *, NSError *))completion {
  [self shaarSubmit:SHAAR_OP_SITE_SETTINGS_ORIGINS profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1} completion:^(NSDictionary *result, NSError *error) {
    NSArray *origins = result[@"origins"];
    if (error || ![origins isKindOfClass:NSArray.class]) {
      completion(nil, error ?: ARCBridgeError(@"Site permissions could not be read for this profile."));
      return;
    }
    for (id origin in origins) if (!ARCIsSiteOrigin(origin)) {
      completion(nil, ARCBridgeError(@"Site permissions could not be read for this profile."));
      return;
    }
    completion(origins, nil);
  }];
}

- (void)resetSitePermissionsForOrigin:(NSString *)origin profileID:(NSString *)profileID
                           completion:(void (^)(NSError *))completion {
  if (!ARCIsSiteOrigin(origin)) { completion(ARCBridgeError(@"Invalid site setting.")); return; }
  [self shaarSubmit:SHAAR_OP_SITE_SETTINGS_RESET profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"origin": origin}
        completion:^(NSDictionary *result, NSError *error) { completion(error); }];
}

- (NSNumber *)thirdPartyCookiesBlockedForProfileID:(NSString *)profileID {
  return [self shaarHasProfileID:profileID] ? ShaarCookiePolicyCache(self)[profileID] : nil;
}

- (NSNumber *)thirdPartyCookiesManagedForProfileID:(NSString *)profileID {
  return [self shaarHasProfileID:profileID] ? ShaarManagedCookiePolicyCache(self)[profileID] : nil;
}

- (void)setThirdPartyCookiesBlocked:(BOOL)blocked profileID:(NSString *)profileID
                         completion:(void (^)(NSError *))completion {
  [self shaarSubmit:SHAAR_OP_THIRD_PARTY_COOKIES_SET profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"blocked": @(blocked)}
        completion:^(NSDictionary *result, NSError *error) {
    NSNumber *effective = result[@"blocked"];
    NSNumber *managed = result[@"managed"];
    if (!error && [effective isKindOfClass:NSNumber.class] &&
        [managed isKindOfClass:NSNumber.class] && effective.boolValue == blocked) {
      ShaarCookiePolicyCache(self)[profileID] = effective;
      ShaarManagedCookiePolicyCache(self)[profileID] = managed;
    }
    completion(error ?: (effective && managed && effective.boolValue == blocked
        ? nil : ARCBridgeError(@"The cookie policy was not saved.")));
  }];
}

- (void)deleteEngineProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (!ARCIsCanonicalID(profileID)) {
    completion(ARCBridgeError(@"Close private windows before deleting this profile."));
    return;
  }
  if (![self shaarDeleteProfileID:profileID completion:completion]) {
    completion(ARCBridgeError(@"Close private windows before deleting this profile."));
    return;
  }
  [ShaarCookiePolicyCache(self) removeObjectForKey:profileID];
  [ShaarManagedCookiePolicyCache(self) removeObjectForKey:profileID];
}

- (NSDictionary<NSString *, id> *)securityInfoForTabID:(NSString *)tabID profileID:(NSString *)profileID {
  return [self shaarSecurityInfoForTabID:tabID profileID:profileID];
}

- (void)siteSettingsForOrigin:(NSString *)origin profileID:(NSString *)profileID
                   completion:(void (^)(NSDictionary<NSString *, NSDictionary *> *, NSError *))completion {
  if (!ARCIsSiteOrigin(origin)) { completion(nil, ARCBridgeError(@"Site settings need a web address.")); return; }
  [self shaarSubmit:SHAAR_OP_SITE_SETTINGS_GET profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"origin": origin}
        completion:^(NSDictionary *result, NSError *error) {
    NSDictionary *settings = result[@"settings"];
    completion([settings isKindOfClass:NSDictionary.class] ? settings : nil,
               error ?: ([settings isKindOfClass:NSDictionary.class] ? nil : ARCBridgeError(@"Site settings could not be read for this profile.")));
  }];
}

- (void)setSiteSetting:(NSString *)type value:(NSString *)value origin:(NSString *)origin
             profileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  if (!ARCIsSiteOrigin(origin) || ![type isKindOfClass:NSString.class] || type.length > 64 ||
      ![@[@"allow", @"block", @"ask", @"default"] containsObject:value]) {
    completion(ARCBridgeError(@"Invalid site setting.")); return;
  }
  [self shaarSubmit:SHAAR_OP_SITE_SETTINGS_SET profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"origin": origin, @"type": type, @"value": value}
        completion:^(NSDictionary *result, NSError *error) { completion(error); }];
}

- (void)clearSiteDataForOrigin:(NSString *)origin profileID:(NSString *)profileID
                    completion:(void (^)(NSError *))completion {
  if (!ARCIsSiteOrigin(origin)) { completion(ARCBridgeError(@"Site data needs a web address.")); return; }
  [self shaarSubmit:SHAAR_OP_SITE_DATA_CLEAR profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"origin": origin}
        completion:^(NSDictionary *result, NSError *error) {
    completion(error ?: ([result[@"complete"] isEqual:@YES] ? nil : ARCBridgeError(@"Site data was not fully cleared.")));
  }];
}

- (void)clearCacheForProfileID:(NSString *)profileID completion:(void (^)(NSError *))completion {
  [self shaarSubmit:SHAAR_OP_BROWSING_DATA_CLEAR profileID:profileID tabID:nil
           payload:@{@"schemaVersion": @1, @"types": @[@"cache"]}
        completion:^(NSDictionary *result, NSError *error) {
    completion(error ?: ([result[@"complete"] isEqual:@YES] ? nil : ARCBridgeError(@"The cache was not cleared.")));
  }];
}

- (void)clearCookiesForTabID:(NSString *)tabID profileID:(NSString *)profileID
                  completion:(void (^)(NSError *))completion {
  NSDictionary *security = [self shaarSecurityInfoForTabID:tabID profileID:profileID];
  NSString *origin = security[@"origin"];
  if (!ARCIsSiteOrigin(origin)) {
    completion(ARCBridgeError(@"Cookies can only be cleared for a web page."));
    return;
  }
  [self shaarSubmit:SHAAR_OP_SITE_COOKIES_CLEAR profileID:profileID tabID:tabID
           payload:@{@"schemaVersion": @1, @"origin": origin}
        completion:^(NSDictionary *result, NSError *error) {
    completion(error ?: ([result[@"complete"] isEqual:@YES] ? nil : ARCBridgeError(@"Some cookies were not cleared.")));
  }];
}

- (void)siteCookiesForTabID:(NSString *)tabID profileID:(NSString *)profileID origin:(NSString *)origin
                completion:(void (^)(NSArray<NSDictionary<NSString *, id> *> *, NSError *))completion {
  if (!ARCIsSelectedCookieScope(self, tabID, profileID, origin)) {
    completion(nil, ARCBridgeError(@"The selected page has changed."));
    return;
  }
  [self shaarSubmit:ARCSiteCookieItems profileID:profileID tabID:tabID
           payload:@{@"schemaVersion": @1, @"origin": origin}
        completion:^(NSDictionary *result, NSError *error) {
    NSArray *cookies = result[@"cookies"];
    completion([cookies isKindOfClass:NSArray.class] ? cookies : nil,
               error ?: ([cookies isKindOfClass:NSArray.class] ? nil : ARCBridgeError(@"Cookies could not be read.")));
  }];
}

- (void)setSiteCookie:(NSDictionary<NSString *, id> *)cookie tabID:(NSString *)tabID
           profileID:(NSString *)profileID origin:(NSString *)origin
          completion:(void (^)(NSError *))completion {
  [self shaarMutateSiteCookie:cookie operation:ARCSiteCookieSet tabID:tabID
                   profileID:profileID origin:origin completion:completion];
}

- (void)deleteSiteCookie:(NSDictionary<NSString *, id> *)cookie tabID:(NSString *)tabID
              profileID:(NSString *)profileID origin:(NSString *)origin
             completion:(void (^)(NSError *))completion {
  [self shaarMutateSiteCookie:cookie operation:ARCSiteCookieDelete tabID:tabID
                   profileID:profileID origin:origin completion:completion];
}

- (void)shaarMutateSiteCookie:(NSDictionary<NSString *, id> *)cookie operation:(shaar_operation)operation
                       tabID:(NSString *)tabID profileID:(NSString *)profileID origin:(NSString *)origin
                  completion:(void (^)(NSError *))completion {
  if (!ARCIsSelectedCookieScope(self, tabID, profileID, origin) ||
      ![cookie isKindOfClass:NSDictionary.class]) {
    completion(ARCBridgeError(@"The selected page has changed."));
    return;
  }
  NSMutableDictionary *payload = [cookie mutableCopy];
  payload[@"schemaVersion"] = @1;
  payload[@"origin"] = origin;
  [self shaarSubmit:operation profileID:profileID tabID:tabID payload:payload
        completion:^(NSDictionary *result, NSError *error) {
    completion(error ?: ([result[@"complete"] isEqual:@YES] ? nil : ARCBridgeError(@"The cookie was not changed.")));
  }];
}

@end
