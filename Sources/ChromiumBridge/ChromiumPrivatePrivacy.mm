// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarPrivateSupport.h"

#include <dlfcn.h>
#include <cstring>

static NSString *ARCPrivateOrigin(NSString *url) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:url];
  if (![@[@"https", @"http"] containsObject:parts.scheme.lowercaseString] || !parts.host.length ||
      parts.user.length || parts.password.length) return nil;
  parts.path = @"";
  parts.query = nil;
  parts.fragment = nil;
  return parts.string;
}

namespace {
using CookieSetting = decltype(&shaar_private_session_cookie_setting);
using TrackerRules = decltype(&shaar_private_session_tracker_rules);
using TrackerStatus = decltype(&shaar_private_session_tracker_status);
using TrackerAllowance = decltype(&shaar_private_session_tracker_allowance);
using PrivacyStatus = shaar_error_code (*)(shaar_private_session *, char *, size_t,
                                           shaar_error *);

CookieSetting PrivateCookieSymbol() {
  return reinterpret_cast<CookieSetting>(dlsym(RTLD_DEFAULT,
      "shaar_private_session_cookie_setting"));
}

TrackerRules PrivateTrackerRulesSymbol() {
  return reinterpret_cast<TrackerRules>(dlsym(RTLD_DEFAULT,
      "shaar_private_session_tracker_rules"));
}

TrackerStatus PrivateTrackerStatusSymbol() {
  return reinterpret_cast<TrackerStatus>(dlsym(RTLD_DEFAULT,
      "shaar_private_session_tracker_status"));
}

TrackerAllowance PrivateTrackerAllowanceSymbol() {
  return reinterpret_cast<TrackerAllowance>(dlsym(RTLD_DEFAULT,
      "shaar_private_session_tracker_allowance"));
}

PrivacyStatus PrivatePrivacyStatusSymbol() {
  return reinterpret_cast<PrivacyStatus>(dlsym(RTLD_DEFAULT,
      "shaar_private_session_privacy_status"));
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

BOOL ARCPrivateShaarInstallTrackerRules(shaar_private_session *session) {
  auto install = PrivateTrackerRulesSymbol();
  if (!session || !install) return NO;
  NSURL *url = [[NSBundle mainBundle].resourceURL
      URLByAppendingPathComponent:@"Privacy/tracker-domains.json"];
  NSData *data = [NSData dataWithContentsOfURL:url
      options:NSDataReadingMappedIfSafe error:nil];
  NSDictionary *rules = data ? [NSJSONSerialization JSONObjectWithData:data
      options:0 error:nil] : nil;
  NSArray *domains = [rules[@"domains"] isKindOfClass:NSArray.class]
      ? rules[@"domains"] : nil;
  NSString *revision = [rules[@"revision"] isKindOfClass:NSString.class]
      ? rules[@"revision"] : nil;
  if (![rules[@"schema"] isEqual:@1] || !revision.length ||
      !domains.count || domains.count > 100000) return NO;
  NSData *json = [NSJSONSerialization dataWithJSONObject:domains options:0
      error:nil];
  if (!json || json.length > 4 * 1024 * 1024) return NO;
  shaar_error error = ARCPrivateShaarEmptyError();
  return install(session, ARCPrivateShaarBytes(revision),
      {(const char *)json.bytes, json.length}, &error) == SHAAR_OK;
}

@implementation ARCShaarRuntime (PrivatePrivacy)

- (BOOL)privatePrivacyAvailable {
  return PrivateCookieSymbol() && PrivateTrackerRulesSymbol() &&
         PrivateTrackerStatusSymbol() && PrivateTrackerAllowanceSymbol() &&
         PrivatePrivacyStatusSymbol();
}

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
  auto status = PrivateTrackerStatusSymbol();
  auto policy = PrivatePrivacyStatusSymbol();
  if (!status || !policy) {
    completion(@{@"error": @"Private privacy status is unavailable."});
    return;
  }
  char policyJSON[4096] = {};
  shaar_error error = ARCPrivateShaarEmptyError();
  if (policy(Session(context), policyJSON, sizeof(policyJSON), &error) != SHAAR_OK) {
    completion(@{@"error": @"Private privacy status failed."});
    return;
  }
  const char *end = static_cast<const char *>(memchr(policyJSON, '\0', sizeof(policyJSON)));
  NSData *data = end ? [NSData dataWithBytes:policyJSON length:end - policyJSON] : nil;
  NSDictionary *values = data ? [NSJSONSerialization JSONObjectWithData:data
      options:0 error:nil] : nil;
  if (![values isKindOfClass:NSDictionary.class]) {
    completion(@{@"error": @"Private privacy status is malformed."});
    return;
  }
  char revision[201] = {};
  int domains = 0;
  int blocked = 0;
  error = ARCPrivateShaarEmptyError();
  if (status(Session(context), revision, sizeof(revision), &domains,
             &blocked, &error) != SHAAR_OK) {
    completion(@{@"error": @"Private tracker status failed."});
    return;
  }
  NSMutableDictionary *result = [values mutableCopy];
  result[@"trackerProtectionEnabled"] = @YES;
  result[@"trackerRulesRevision"] = [NSString stringWithUTF8String:revision] ?: @"";
  result[@"trackerDomainCount"] = @(domains);
  result[@"blockedTrackerRequests"] = @(blocked);
  completion(result);
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
  NSDictionary *context = ARCPrivateShaarState(self)[@"contexts"][contextID];
  auto setting = PrivateTrackerAllowanceSymbol();
  if (!context || !setting || ![ARCPrivateOrigin(origin) isEqual:origin]) {
    completion(@{@"error": @"Invalid private tracker origin or context."});
    return;
  }
  int allowed = 0;
  shaar_error error = ARCPrivateShaarEmptyError();
  if (setting(Session(context), ARCPrivateShaarBytes(origin), 1, allow,
              &allowed, &error) != SHAAR_OK) {
    completion(@{@"error": @"Private tracker allowance failed."});
    return;
  }
  completion(@{@"ok": @YES, @"origin": origin,
    @"trackersAllowed": @(allowed != 0)});
}

- (void)preparePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID url:(NSString *)url {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  NSMutableDictionary *tab = state[@"tabs"][tabID];
  NSUInteger generation = [tab[@"requestGeneration"] unsignedIntegerValue] + 1;
  tab[@"requestGeneration"] = @(generation);
  tab[@"requestedURL"] = url;
  tab[@"navigationStage"] = @"cookie-setting";
  NSString *origin = ARCPrivateOrigin(url);
  if (origin) {
    BOOL grant = [self shaarPrivateOriginAllowed:origin
                                sourceProfileID:context[@"sourceProfileID"]
                              excludingWindowID:nil];
    if (!SetCookie(context, origin, YES, grant, nullptr)) {
      tab[@"navigationStage"] = @"cookie-setting-failed";
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
  NSMutableDictionary *tab = state[@"tabs"][tabID];
  tab[@"navigationStage"] =
      [NSString stringWithFormat:@"site-setting-%lu", (unsigned long)index];
  BOOL submitted = ARCPrivateShaarSubmit(self, Scope(context), Window(window),
      Tab(tab), SHAAR_OP_SITE_SETTINGS_SET,
      @{@"schemaVersion": @1, @"origin": origin, @"type": types[index],
        @"value": @"block"}, ^(NSDictionary *reply) {
    if ([ARCPrivateShaarState(self)[@"tabs"][tabID][@"requestGeneration"]
            unsignedIntegerValue] != generation) return;
    if (reply[@"error"]) {
      tab[@"navigationStage"] = [NSString
          stringWithFormat:@"site-setting-%lu-failed", (unsigned long)index];
      if (self.onPrivateNavigationFailed)
        self.onPrivateNavigationFailed(contextID, windowID, tabID,
          @"Private site protections could not be applied.");
      return;
    }
    [self applyPrivateSettingsForTabID:tabID windowID:windowID
                             contextID:contextID url:url origin:origin index:index + 1
                            generation:generation];
  }, nullptr);
  if (!submitted)
    tab[@"navigationStage"] = [NSString
        stringWithFormat:@"site-setting-%lu-rejected", (unsigned long)index];
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
  NSMutableDictionary *tab = state[@"tabs"][tabID];
  tab[@"navigationStage"] = @"navigation-submitting";
  BOOL submitted = ARCPrivateShaarSubmit(self, Scope(context), Window(window),
      Tab(tab), SHAAR_OP_TAB_NAVIGATE,
      @{@"schemaVersion": @1, @"url": url, @"userInitiated": @YES},
      ^(NSDictionary *reply) {
    if ([ARCPrivateShaarState(self)[@"tabs"][tabID][@"requestGeneration"]
            unsignedIntegerValue] != generation) return;
    tab[@"navigationStage"] = reply[@"error"] ? @"navigation-failed" : @"navigation-accepted";
    if (reply[@"error"] && self.onPrivateNavigationFailed)
      self.onPrivateNavigationFailed(contextID, windowID, tabID,
        @"Private navigation failed.");
  }, nullptr);
  if (!submitted) tab[@"navigationStage"] = @"navigation-rejected";
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
