// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarPrivateSupport.h"

#include <dlfcn.h>

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
    entry[@"privacyError"] = ARCBridgeLocalizedString(@"Private site protections could not be applied.");
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

namespace {
using CookieSetting = decltype(&shaar_private_session_cookie_setting);

CookieSetting PrivateCookieSymbol() {
  return reinterpret_cast<CookieSetting>(dlsym(RTLD_DEFAULT,
      "shaar_private_session_cookie_setting"));
}

shaar_private_session *Session(NSDictionary *context) {
  return (shaar_private_session *)((NSValue *)context[@"session"]).pointerValue;
}

shaar_window *Window(NSDictionary *entry) {
  return (shaar_window *)((NSValue *)entry[@"handle"]).pointerValue;
}

shaar_tab *Tab(NSDictionary *entry) {
  return (shaar_tab *)((NSValue *)entry[@"handle"]).pointerValue;
}

shaar_scope Scope(NSDictionary *context) {
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = Session(context);
  return scope;
}

BOOL SetCookie(NSDictionary *context, NSString *origin, BOOL set, BOOL allow,
               BOOL *allowed) {
  auto function = PrivateCookieSymbol();
  if (!function || !context || !origin) return NO;
  shaar_error error = ARCPrivateShaarEmptyError();
  int result = 0;
  shaar_error_code status = function(Session(context), ARCPrivateShaarBytes(origin),
                                      set, allow, &result, &error);
  if (status != SHAAR_OK) return NO;
  if (allowed) *allowed = result != 0;
  return YES;
}
}  // namespace

@implementation ARCShaarRuntime (PrivatePrivacy)

- (BOOL)privatePrivacyAvailable { return NO; }

- (BOOL)shaarPrivateOriginAllowed:(NSString *)origin sourceProfileID:(NSString *)sourceID
                  excludingWindowID:(NSString *)excluded {
  NSDictionary *state = ARCPrivateShaarState(self);
  for (NSString *windowID in state[@"windows"]) {
    if ([windowID isEqual:excluded]) continue;
    NSDictionary *window = state[@"windows"][windowID];
    NSString *contextID = window[@"contextID"];
    NSDictionary *context = state[@"contexts"][contextID];
    if ([context[@"sourceProfileID"] isEqual:sourceID] &&
        [window[@"cookieOrigins"] containsObject:origin]) return YES;
  }
  return NO;
}

- (void)privatePrivacyStatusForContextID:(NSString *)contextID
                              completion:(void (^)(NSDictionary *))completion {
  NSDictionary *context = ARCPrivateShaarState(self)[@"contexts"][contextID];
  if (!context) { completion(@{@"error": @"Private context is unavailable."}); return; }
  // The private-session ABI does not yet expose tracker request protection.
  completion(@{@"error": @"Private tracker protection is unavailable in this engine."});
}

- (void)setPrivateCookieSettingForContextID:(NSString *)contextID origin:(NSString *)origin
                                      value:(NSString *)value
                                 completion:(void (^)(NSDictionary *))completion {
  NSDictionary *context = ARCPrivateShaarState(self)[@"contexts"][contextID];
  if (![ARCPrivateOrigin(origin) isEqual:origin] ||
      ![@[@"allow", @"block"] containsObject:value] || !context) {
    completion(@{@"error": @"Invalid private cookie setting."});
    return;
  }
  BOOL allowed = NO;
  if (!SetCookie(context, origin, YES, [value isEqual:@"allow"], &allowed)) {
    completion(@{@"error": @"Private cookie setting failed."});
    return;
  }
  completion(@{@"ok": @YES, @"value": allowed ? @"allow" : @"block"});
}

- (void)setPrivateTrackerAllowanceForContextID:(NSString *)contextID origin:(NSString *)origin
                                          allow:(BOOL)allow
                                     completion:(void (^)(NSDictionary *))completion {
  completion(@{@"error": @"Private tracker allowance is unavailable in this engine."});
}

- (void)preparePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID url:(NSString *)url {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  NSMutableDictionary *tab = state[@"tabs"][tabID];
  NSUInteger generation = [tab[@"requestGeneration"] unsignedIntegerValue] + 1;
  tab[@"requestGeneration"] = @(generation);
  NSString *origin = ARCPrivateOrigin(url);
  if (origin) {
    BOOL grant = [self shaarPrivateOriginAllowed:origin
                                sourceProfileID:context[@"sourceProfileID"]
                              excludingWindowID:nil];
    if (!SetCookie(context, origin, YES, grant, nullptr)) {
      if (self.onPrivateNavigationFailed)
        self.onPrivateNavigationFailed(contextID, windowID, tabID,
          @"Private cookie protection could not be applied.");
      return;
    }
  }
  [self applyPrivateSettingsForTabID:tabID windowID:windowID
                            contextID:contextID url:url origin:origin index:0
                           generation:generation];
}

- (void)applyPrivateSettingsForTabID:(NSString *)tabID windowID:(NSString *)windowID
                           contextID:(NSString *)contextID url:(NSString *)url
                              origin:(NSString *)origin index:(NSUInteger)index
                          generation:(NSUInteger)generation {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
  NSDictionary *state = ARCPrivateShaarState(self);
  if ([state[@"tabs"][tabID][@"requestGeneration"] unsignedIntegerValue] != generation)
    return;
  NSArray<NSString *> *types = @[@"camera", @"microphone", @"location", @"notifications"];
  if (!origin || index == types.count) {
    [self startPrivateNavigationForTabID:tabID windowID:windowID
                               contextID:contextID url:url generation:generation];
    return;
  }
  NSDictionary *context = state[@"contexts"][contextID];
  NSDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  BOOL submitted = ARCPrivateShaarSubmit(self, Scope(context), Window(window),
      Tab(tab), SHAAR_OP_SITE_SETTINGS_SET,
      @{@"schemaVersion": @1, @"origin": origin, @"type": types[index],
        @"value": @"block"}, ^(NSDictionary *reply) {
    if ([ARCPrivateShaarState(self)[@"tabs"][tabID][@"requestGeneration"]
            unsignedIntegerValue] != generation) return;
    if (reply[@"error"]) {
      if (self.onPrivateNavigationFailed)
        self.onPrivateNavigationFailed(contextID, windowID, tabID,
          @"Private site protections could not be applied.");
      return;
    }
    [self applyPrivateSettingsForTabID:tabID windowID:windowID
                             contextID:contextID url:url origin:origin index:index + 1
                            generation:generation];
  });
  if (!submitted && self.onPrivateNavigationFailed)
    self.onPrivateNavigationFailed(contextID, windowID, tabID,
      @"Private site protections could not be applied.");
}

- (void)startPrivateNavigationForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID url:(NSString *)url
                             generation:(NSUInteger)generation {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
  NSDictionary *state = ARCPrivateShaarState(self);
  if ([state[@"tabs"][tabID][@"requestGeneration"] unsignedIntegerValue] != generation)
    return;
  NSDictionary *context = state[@"contexts"][contextID];
  NSDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  BOOL submitted = ARCPrivateShaarSubmit(self, Scope(context), Window(window),
      Tab(tab), SHAAR_OP_TAB_NAVIGATE,
      @{@"schemaVersion": @1, @"url": url, @"userInitiated": @YES},
      ^(NSDictionary *reply) {
    if ([ARCPrivateShaarState(self)[@"tabs"][tabID][@"requestGeneration"]
            unsignedIntegerValue] != generation) return;
    if (reply[@"error"] && self.onPrivateNavigationFailed)
      self.onPrivateNavigationFailed(contextID, windowID, tabID,
        @"Private navigation failed.");
  });
  if (!submitted && self.onPrivateNavigationFailed)
    self.onPrivateNavigationFailed(contextID, windowID, tabID,
      @"Private navigation failed.");
}

- (void)privateCookiesForTabID:(NSString *)tabID windowID:(NSString *)windowID
                     contextID:(NSString *)contextID origin:(NSString *)origin
                    completion:(void (^)(NSNumber *, NSError *))completion {
  NSDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  NSDictionary *context = state[@"contexts"][contextID];
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID] ||
      ![window[@"selectedTabID"] isEqual:tabID] ||
      ![ARCPrivateOrigin(tab[@"url"]) isEqual:origin]) {
    completion(nil, ARCBridgeError(@"Select a private web page to change cookies."));
    return;
  }
  BOOL allowed = NO;
  if (!SetCookie(context, origin, NO, NO, &allowed)) {
    completion(nil, ARCBridgeError(@"The private cookie setting could not be read."));
    return;
  }
  completion(@(allowed), nil);
}

- (void)setPrivateCookiesAllowed:(BOOL)allowed tabID:(NSString *)tabID
                       windowID:(NSString *)windowID contextID:(NSString *)contextID
                          origin:(NSString *)origin completion:(void (^)(NSError *))completion {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSMutableDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  NSDictionary *context = state[@"contexts"][contextID];
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID] ||
      ![window[@"selectedTabID"] isEqual:tabID] ||
      ![ARCPrivateOrigin(tab[@"url"]) isEqual:origin] ||
      !SetCookie(context, origin, YES, allowed, nullptr)) {
    completion(ARCBridgeError(@"The private cookie setting was not applied."));
    return;
  }
  for (NSMutableDictionary *other in [state[@"windows"] allValues]) {
    NSDictionary *owner = state[@"contexts"][other[@"contextID"]];
    if ([owner[@"sourceProfileID"] isEqual:context[@"sourceProfileID"]])
      [other[@"cookieOrigins"] removeObject:origin];
  }
  if (allowed) {
    if (!window[@"cookieOrigins"]) window[@"cookieOrigins"] = [NSMutableSet set];
    [window[@"cookieOrigins"] addObject:origin];
  }
  completion(nil);
}

- (void)revokePrivateCookiesForWindowID:(NSString *)windowID {
  NSDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *window = state[@"windows"][windowID];
  NSDictionary *context = state[@"contexts"][window[@"contextID"]];
  NSString *sourceID = context[@"sourceProfileID"];
  for (NSString *origin in window[@"cookieOrigins"]) {
    if (![self shaarPrivateOriginAllowed:origin sourceProfileID:sourceID
                      excludingWindowID:windowID])
      SetCookie(context, origin, YES, NO, nullptr);
  }
}

@end
