// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumProbeRoot.h"
#import "ChromiumShaarPrivateSupport.h"

#include <dlfcn.h>

namespace {
template <typename Function>
Function PrivateSymbol(const char *name) {
  return reinterpret_cast<Function>(dlsym(RTLD_DEFAULT, name));
}

NSString *PrivateString(shaar_bytes bytes) {
  if (!bytes.data || !bytes.size) return @"";
  return [[NSString alloc] initWithBytes:bytes.data length:bytes.size
                               encoding:NSUTF8StringEncoding] ?: @"";
}

shaar_scope PrivateScope(NSDictionary *context) {
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = (shaar_private_session *)((NSValue *)context[@"session"]).pointerValue;
  return scope;
}

shaar_window *PrivateWindow(NSDictionary *entry) {
  return (shaar_window *)((NSValue *)entry[@"handle"]).pointerValue;
}

shaar_tab *PrivateTab(NSDictionary *entry) {
  return (shaar_tab *)((NSValue *)entry[@"handle"]).pointerValue;
}
}  // namespace

@implementation ARCChromiumRuntime (PrivateBrowsing)

- (BOOL)privatePrivacyAvailable { return _services.privatePrivacyAvailable; }

- (void)privatePrivacyCall:(NSString *)method contextID:(NSString *)contextID
                     args:(NSDictionary *)args completion:(void (^)(NSDictionary *))completion {
  NSAssert(NSThread.isMainThread, @"Private settings require the UI thread");
  NSDictionary *context = _privateProbeContexts[contextID];
  NSString *sourceID = context[@"sourceProfileID"];
  if (!_services.privatePrivacyAvailable || !context || !_profiles[sourceID] ||
      [context[@"profile"] destroyed]) {
    completion(@{@"error": @"Private context is unavailable."});
    return;
  }
  NSMutableDictionary *payload = [args mutableCopy];
  payload[@"offTheRecord"] = @YES;
  [_services call:method profileID:sourceID args:payload completion:completion];
}

- (void)privatePrivacyStatusForContextID:(NSString *)contextID
  completion:(void (^)(NSDictionary *))completion {
  [self privatePrivacyCall:@"private.privacy.get" contextID:contextID args:@{}
                completion:completion];
}

- (void)setPrivateCookieSettingForContextID:(NSString *)contextID origin:(NSString *)origin
  value:(NSString *)value completion:(void (^)(NSDictionary *))completion {
  [self privatePrivacyCall:@"site_settings.set" contextID:contextID
                     args:@{@"origin": origin ?: @"", @"type": @"cookies", @"value": value ?: @""}
               completion:completion];
}

- (void)setPrivateTrackerAllowanceForContextID:(NSString *)contextID origin:(NSString *)origin
  allow:(BOOL)allow completion:(void (^)(NSDictionary *))completion {
  [self privatePrivacyCall:@"private.tracker.site.set" contextID:contextID
                     args:@{@"origin": origin ?: @"", @"allow": @(allow)}
               completion:completion];
}

- (BOOL)privateContextEnabled { return _engine != nil && !_closingBrowser; }

- (BOOL)privateIdentityOccupied:(NSString *)identity {
  return _profiles[identity] || _windows[identity] || _tabs[identity] ||
    _privateProbeContexts[identity] || _privateProbeWindows[identity] || _privateProbeTabs[identity] ||
    _privateProbePendingContexts[identity] || [_privateProbePendingWindows containsObject:identity] ||
    [_privateProbePendingTabs containsObject:identity] || _profileWaiters[identity] ||
    [_retiredWindowIDs containsObject:identity];
}

- (BOOL)isPrivateIdentity:(NSString *)identity {
  return _privateProbeContexts[identity] || _privateProbeWindows[identity] || _privateProbeTabs[identity] ||
    _privateProbePendingContexts[identity] || [_privateProbePendingWindows containsObject:identity] ||
    [_privateProbePendingTabs containsObject:identity];
}

- (BOOL)privateIdentityIsAvailable:(NSString *)identity {
  return identity.length && ![self privateIdentityOccupied:identity];
}

- (BOOL)privateURLIsAllowed:(NSString *)url {
  if (!url.length || [url rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
    return NO;
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  BOOL validPort = !components.port || (components.port.integerValue > 0 && components.port.integerValue <= 65535);
  BOOL webURL = components.URL && validPort &&
    [@[@"http", @"https"] containsObject:components.scheme.lowercaseString] && components.host.length &&
    !components.user.length && !components.password.length;
  return webURL || [url isEqualToString:@"about:blank"];
}

- (BOOL)privateWindowContextOwned:(NSString *)contextID windowID:(NSString *)windowID {
  NSDictionary *context = _privateProbeContexts[contextID];
  NSDictionary *window = _privateProbeWindows[windowID];
  NSString *sourceID = context[@"sourceProfileID"];
  NSDictionary *lease = _privateProbeSourceLeases[sourceID];
  return [self privateContextEnabled] && context && window &&
    [window[@"contextID"] isEqualToString:contextID] && ![window[@"closing"] boolValue] &&
    _profiles[sourceID] == context[@"sourceProfile"] &&
    ![context[@"sourceProfile"] destroyed] && ![context[@"sourceProfile"] offTheRecord] &&
    ![context[@"profile"] destroyed] && [context[@"profile"] offTheRecord] &&
    lease[@"profile"] == context[@"profile"] && [lease[@"contextIDs"] containsObject:contextID];
}

- (void)createPrivateContextID:(NSString *)contextID sourceProfileID:(NSString *)sourceProfileID
                        completion:(void (^)(BOOL, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Private probe creation requires the UI thread");
  ArdiaCoreProfile *source = _profiles[sourceProfileID];
  if (![self privateContextEnabled] || !ARCIsCanonicalID(contextID) || !ARCIsCanonicalID(sourceProfileID) ||
      [_deletingProfileIDs containsObject:sourceProfileID] ||
      !source || source.destroyed || source.offTheRecord ||
      ![self privateIdentityIsAvailable:contextID]) {
    completion(NO, ARCBridgeError(@"Invalid private probe context or source profile."));
    return;
  }
  if (_privateProbePendingContexts[contextID]) {
    completion(NO, ARCBridgeError(@"Private probe context identity is already pending."));
    return;
  }
  if (_services.privatePrivacyAvailable &&
      ![_privateTrackerPreparedSources containsObject:sourceProfileID]) {
    [_services preparePrivateTrackerRulesForProfileID:sourceProfileID completion:^(BOOL ready) {
      if (!ready) {
        completion(NO, ARCBridgeError(@"Private site protections could not be applied."));
        return;
      }
      [self->_privateTrackerPreparedSources addObject:sourceProfileID];
      [self createPrivateContextID:contextID sourceProfileID:sourceProfileID completion:completion];
    }];
    return;
  }
  NSMutableDictionary *lease = _privateProbeSourceLeases[sourceProfileID];
  ArdiaCoreProfile *leasedProfile = NSClassFromString(@"ArdiaCoreProfile") &&
    [lease[@"profile"] isKindOfClass:NSClassFromString(@"ArdiaCoreProfile")]
    ? lease[@"profile"] : nil;
  if (lease && leasedProfile && !leasedProfile.destroyed) {
    [lease[@"contextIDs"] addObject:contextID];
    _privateProbeContexts[contextID] = [@{@"sourceProfileID": sourceProfileID,
      @"sourceProfile": source, @"profile": leasedProfile, @"windows": [NSMutableSet set],
      @"pendingWindows": [NSMutableSet set]} mutableCopy];
    completion(YES, nil);
    return;
  }
  BOOL startFactory = lease == nil;
  if (!lease) {
    lease = [@{@"sourceProfile": source, @"pending": [NSMutableDictionary dictionary],
      @"contextIDs": [NSMutableSet set], @"profile": NSNull.null} mutableCopy];
    _privateProbeSourceLeases[sourceProfileID] = lease;
  }
  lease[@"pending"][contextID] = [completion copy];
  _privateProbePendingContexts[contextID] = sourceProfileID;
  if (!startFactory) return;
  NSMutableDictionary *capturedLease = lease;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_privateProbeSourceLeases[sourceProfileID] != capturedLease ||
        ![self privateContextEnabled]) {
      if (self->_privateProbeSourceLeases[sourceProfileID] == capturedLease) {
        NSDictionary *pending = [capturedLease[@"pending"] copy];
        [capturedLease[@"pending"] removeAllObjects];
        [self->_privateProbeSourceLeases removeObjectForKey:sourceProfileID];
        for (NSString *pendingID in pending) {
          [self->_privateProbePendingContexts removeObjectForKey:pendingID];
          void (^waiter)(BOOL, NSError *) = pending[pendingID];
          waiter(NO, ARCBridgeError(@"Off-the-record profile creation was cancelled."));
        }
      }
      return;
    }
    [self->_engine offTheRecordProfileFor:source completion:^(ArdiaCoreProfile *privateProfile, NSString *message) {
        NSMutableDictionary *current = self->_privateProbeSourceLeases[sourceProfileID];
        if (current != capturedLease) {
          // A stale callback cannot release ArdiaCore's shared primary OTR profile.
          return;
        }
        BOOL valid = self->_profiles[sourceProfileID] == source && !source.destroyed && !source.offTheRecord &&
          privateProfile && !privateProfile.destroyed && privateProfile.offTheRecord && privateProfile != source;
        if (valid) {
          // These are the only relevant booleans exposed by the pinned host-pref allowlist.
          for (NSString *key in @[@"credentials_enable_service", @"autofill.profile_enabled", @"autofill.credit_card_enabled"]) {
            [privateProfile setBoolPreference:key value:NO];
            valid = valid && [[privateProfile boolPreference:key] isEqual:@NO];
          }
          if (valid) current[@"profile"] = privateProfile;
        }
        NSDictionary *pending = [current[@"pending"] copy];
        [current[@"pending"] removeAllObjects];
        NSMutableSet<NSString *> *registered = [NSMutableSet set];
        for (NSString *pendingID in pending) {
          [self->_privateProbePendingContexts removeObjectForKey:pendingID];
          if (valid && [self privateContextEnabled] &&
              [self privateIdentityIsAvailable:pendingID]) {
            [current[@"contextIDs"] addObject:pendingID];
            self->_privateProbeContexts[pendingID] = [@{@"sourceProfileID": sourceProfileID,
              @"sourceProfile": source, @"profile": privateProfile,
              @"windows": [NSMutableSet set], @"pendingWindows": [NSMutableSet set]} mutableCopy];
            [registered addObject:pendingID];
          }
        }
        for (NSString *pendingID in pending) {
          void (^waiter)(BOOL, NSError *) = pending[pendingID];
          NSMutableDictionary *context = self->_privateProbeContexts[pendingID];
          BOOL stillOwned = [registered containsObject:pendingID] &&
            self->_privateProbeSourceLeases[sourceProfileID] == capturedLease &&
            [current[@"contextIDs"] containsObject:pendingID] &&
            context[@"sourceProfile"] == source && context[@"profile"] == privateProfile &&
            self->_profiles[sourceProfileID] == source && !source.destroyed &&
            !privateProfile.destroyed && privateProfile.offTheRecord &&
            [self privateContextEnabled];
          if (stillOwned) {
            waiter(YES, nil);
          } else {
            if (context && [registered containsObject:pendingID]) {
              [self->_privateProbeContexts removeObjectForKey:pendingID];
              [current[@"contextIDs"] removeObject:pendingID];
            }
            waiter(NO, ARCBridgeError(message.length ? message : @"Off-the-record profile creation was rejected."));
          }
        }
        if (self->_privateProbeSourceLeases[sourceProfileID] == capturedLease &&
            [(NSSet *)current[@"contextIDs"] count] == 0 &&
            [(NSDictionary *)current[@"pending"] count] == 0) {
          [self->_privateProbeSourceLeases removeObjectForKey:sourceProfileID];
          if (privateProfile && privateProfile.offTheRecord && privateProfile != source && !privateProfile.destroyed)
            [self->_engine releaseProfile:privateProfile];
        }
    }];
  });
}

- (BOOL)createPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                         tabID:(NSString *)tabID url:(NSString *)url error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Private windows require the UI thread");
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  ArdiaCoreProfile *profile = context[@"profile"];
  if (![self privateContextEnabled] || !ARCIsCanonicalID(windowID) || !ARCIsCanonicalID(tabID) ||
      [windowID isEqualToString:contextID] || [tabID isEqualToString:contextID] ||
      [tabID isEqualToString:windowID] || !context ||
      ![self privateIdentityIsAvailable:windowID] ||
      ![self privateIdentityIsAvailable:tabID] ||
      !profile || profile.destroyed || !profile.offTheRecord || ![self privateURLIsAllowed:url]) {
    if (error) *error = ARCBridgeError(@"Invalid, unknown, closed, or unsupported private navigation.");
    return NO;
  }
  [context[@"pendingWindows"] addObject:windowID];
  [_privateProbePendingWindows addObject:windowID];
  [_privateProbePendingTabs addObject:tabID];
  context[@"pendingReleaseRejected"] = @(![self releasePrivateContextID:contextID]);
  NSMutableDictionary *capturedContext = context;
  NSMutableDictionary *capturedLease = _privateProbeSourceLeases[context[@"sourceProfileID"]];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  BOOL (^creationCurrent)(void) = ^BOOL{
    return [self privateContextEnabled] && self->_privateProbeContexts[contextID] == capturedContext &&
      self->_privateProbeSourceLeases[capturedContext[@"sourceProfileID"]] == capturedLease &&
      self->_profiles[capturedContext[@"sourceProfileID"]] == source && !source.destroyed &&
      capturedContext[@"profile"] == profile && !profile.destroyed && profile.offTheRecord &&
      [capturedContext[@"pendingWindows"] containsObject:windowID] &&
      [self->_privateProbePendingWindows containsObject:windowID] &&
      [self->_privateProbePendingTabs containsObject:tabID];
  };
  ArdiaCoreWindow *native = [[NSClassFromString(@"ArdiaCoreWindow") alloc]
    initWithContentRect:NSMakeRect(0, 0, 640, 480)];
  if (!native || !native.window || !creationCurrent()) {
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Chromium could not create the private window.");
    return NO;
  }
  [native prepareProfile:profile];
  if (!creationCurrent()) {
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Private context retired during window preparation.");
    return NO;
  }
  native.activeProfile = profile;
  ArdiaCoreTab *tab = [native openTab:@"about:blank" profile:profile foreground:YES];
  if (!tab || !native.hostView || !tab.view || !creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Chromium could not create the private tab.");
    return NO;
  }
  // SwiftUI attaches the page only when it is shown. A full-window sibling can cover its shell.
  // Navigation waits for private protection setup below.
  tab.delegate = self;
  if (!creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Private context retired during navigation start.");
    return NO;
  }
  [native activateTab:tab];
  if (!creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Private context retired during tab activation.");
    return NO;
  }
  __weak ARCChromiumRuntime *weakSelf = self;
  id observer = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification
    object:native.window queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *) {
      [weakSelf privateWindowDidCloseID:windowID];
    }];
  _privateProbeWindows[windowID] = [@{@"contextID": contextID, @"native": native,
    @"tabIDs": [NSMutableSet setWithObject:tabID], @"observer": observer,
    @"closing": @NO, @"selectedTabID": tabID} mutableCopy];
  _privateProbeTabs[tabID] = [@{@"contextID": contextID, @"windowID": windowID, @"tab": tab,
    @"closing": @NO} mutableCopy];
  tab.view.hidden = NO;
  [context[@"pendingWindows"] removeObject:windowID];
  [_privateProbePendingWindows removeObject:windowID];
  [_privateProbePendingTabs removeObject:tabID];
  [context[@"windows"] addObject:windowID];
  native.delegate = self;
  [self configurePrivateTab:tab tabID:tabID windowID:windowID contextID:contextID url:url];
  [self publish:tab];
  if (self.onPrivateTabSelected) self.onPrivateTabSelected(contextID, windowID, tabID);
  return YES;
}

- (BOOL)privateOwnerForTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                         tab:(ArdiaCoreTab **)tabOut window:(ArdiaCoreWindow **)windowOut {
  NSDictionary *tabEntry = _privateProbeTabs[tabID];
  NSDictionary *windowEntry = _privateProbeWindows[windowID];
  NSDictionary *context = _privateProbeContexts[contextID];
  ArdiaCoreTab *tab = tabEntry[@"tab"];
  ArdiaCoreWindow *window = windowEntry[@"native"];
  BOOL valid = [self privateContextEnabled] && tabEntry && windowEntry && context && tab && !tab.closed &&
    window && [self privateWindowContextOwned:contextID windowID:windowID] &&
    [tabEntry[@"contextID"] isEqualToString:contextID] &&
    [tabEntry[@"windowID"] isEqualToString:windowID] &&
    [windowEntry[@"contextID"] isEqualToString:contextID] &&
    [windowEntry[@"tabIDs"] containsObject:tabID] && context[@"profile"] == tab.profile &&
    _profiles[context[@"sourceProfileID"]] == context[@"sourceProfile"] &&
    _privateProbeSourceLeases[context[@"sourceProfileID"]][@"profile"] == context[@"profile"] &&
    [_privateProbeSourceLeases[context[@"sourceProfileID"]][@"contextIDs"] containsObject:contextID] &&
    tab.profile.offTheRecord && !tab.profile.destroyed;
  if (valid) {
    if (tabOut) *tabOut = tab;
    if (windowOut) *windowOut = window;
  }
  return valid;
}

- (BOOL)openPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                     url:(NSString *)url error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Private tabs require the UI thread");
  NSDictionary *context = _privateProbeContexts[contextID];
  NSMutableDictionary *windowEntry = _privateProbeWindows[windowID];
  ArdiaCoreWindow *native = windowEntry[@"native"];
  ArdiaCoreProfile *profile = context[@"profile"];
  if (![self privateContextEnabled] || !ARCIsCanonicalID(tabID) || !windowEntry || !context ||
      ![windowEntry[@"contextID"] isEqualToString:contextID] ||
      [windowEntry[@"closing"] boolValue] || !native || ![self privateIdentityIsAvailable:tabID] ||
      !profile || profile.destroyed || !profile.offTheRecord || ![self privateURLIsAllowed:url]) {
    if (error) *error = ARCBridgeError(@"Invalid private tab owner or unsupported navigation.");
    return NO;
  }
  NSMutableDictionary *lease = _privateProbeSourceLeases[context[@"sourceProfileID"]];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  if (!lease || !source || source.destroyed || _profiles[context[@"sourceProfileID"]] != source) {
    if (error) *error = ARCBridgeError(@"The private source lease is unavailable.");
    return NO;
  }
  NSMutableDictionary *capturedContext = _privateProbeContexts[contextID];
  NSMutableDictionary *capturedWindow = windowEntry;
  BOOL (^current)(void) = ^BOOL{
    return [self privateContextEnabled] && self->_privateProbeContexts[contextID] == capturedContext &&
      self->_privateProbeWindows[windowID] == capturedWindow &&
      self->_privateProbeSourceLeases[capturedContext[@"sourceProfileID"]] == lease &&
      self->_profiles[capturedContext[@"sourceProfileID"]] == source && !source.destroyed &&
      capturedContext[@"profile"] == profile && !profile.destroyed && profile.offTheRecord &&
      ![capturedWindow[@"closing"] boolValue] && ![capturedWindow[@"closed"] boolValue] &&
      ![self privateIdentityIsAvailable:tabID];
  };
  if (windowEntry[@"pendingTabs"] == nil) windowEntry[@"pendingTabs"] = [NSMutableSet set];
  if ([windowEntry[@"pendingTabs"] containsObject:tabID]) return NO;
  [windowEntry[@"pendingTabs"] addObject:tabID];
  [_privateProbePendingTabs addObject:tabID];
  ArdiaCoreTab *tab = [native openTab:@"about:blank" profile:profile foreground:NO];
  if (!tab || tab.closed || tab.profile != profile || !tab.view || !native.hostView || !current()) {
    [tab closeNow];
    [windowEntry[@"pendingTabs"] removeObject:tabID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Chromium could not create the private tab.");
    return NO;
  }
  NSMutableDictionary *entry = [@{@"contextID": contextID, @"windowID": windowID, @"tab": tab,
    @"closing": @NO} mutableCopy];
  _privateProbeTabs[tabID] = entry;
  [windowEntry[@"tabIDs"] addObject:tabID];
  [windowEntry[@"pendingTabs"] removeObject:tabID];
  [_privateProbePendingTabs removeObject:tabID];
  tab.delegate = self;
  tab.view.hidden = YES;
  if (!current() || _privateProbeTabs[tabID] != entry) {
    [tab closeNow];
    if (error) *error = ARCBridgeError(@"Private tab owner changed during creation.");
    return NO;
  }
  // Navigation waits for private protection setup below.
  if (!current() || _privateProbeTabs[tabID] != entry) {
    [tab closeNow];
    if (error) *error = ARCBridgeError(@"Private tab owner changed during navigation start.");
    return NO;
  }
  [self configurePrivateTab:tab tabID:tabID windowID:windowID contextID:contextID url:url];
  [self publish:tab];
  return YES;
}

- (BOOL)selectPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  ArdiaCoreWindow *window = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:&window]) return NO;
  window.activeProfile = tab.profile;
  ((NSMutableDictionary *)_privateProbeWindows[windowID])[@"selectedTabID"] = tabID;
  for (NSString *identity in _privateProbeWindows[windowID][@"tabIDs"]) {
    ArdiaCoreTab *ownedTab = _privateProbeTabs[identity][@"tab"];
    ownedTab.view.hidden = ![identity isEqualToString:tabID];
  }
  [window activateTab:tab];
  if (self.onPrivateTabSelected) self.onPrivateTabSelected(contextID, windowID, tabID);
  return YES;
}

- (void)closePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
               completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) {
    completion(NO);
    return;
  }
  NSMutableDictionary *entry = (NSMutableDictionary *)_privateProbeTabs[tabID];
  if ([entry[@"closing"] boolValue] || entry[@"closeCompletion"]) {
    completion(NO);
    return;
  }
  entry[@"closing"] = @YES;
  entry[@"closeCompletion"] = [completion copy];
  [tab close];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (self->_privateProbeTabs[tabID] != entry) return;
    void (^pending)(BOOL) = entry[@"closeCompletion"];
    entry[@"closeCompletion"] = nil;
    entry[@"closing"] = @NO;
    if (pending) pending(NO);
  });
}

- (BOOL)navigatePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID url:(NSString *)url {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  if (![self privateURLIsAllowed:url]) return NO;
  [self configurePrivateTab:tab tabID:tabID windowID:windowID contextID:contextID url:url];
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil];
}

- (BOOL)focusPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  [tab focus];
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil];
}

- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  return [self reloadPrivateTabID:tabID windowID:windowID contextID:contextID mode:ARCPageReloadModeNormal];
}

- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
                    mode:(ARCPageReloadMode)mode {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  if (mode == ARCPageReloadModeBypassingCache) [tab reloadIgnoringCache];
  else [tab reload];
  return YES;
}

- (BOOL)goBackPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] || !tab.canGoBack) return NO;
  [tab goBack];
  return YES;
}

- (BOOL)goForwardPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] || !tab.canGoForward) return NO;
  [tab goForward];
  return YES;
}

- (BOOL)findInPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID
             requestID:(NSString *)requestID text:(NSString *)text forward:(BOOL)forward {
  ArdiaCoreTab *tab = nil;
  NSMutableDictionary *entry = (NSMutableDictionary *)_privateProbeTabs[tabID];
  NSDictionary *window = _privateProbeWindows[windowID];
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil] ||
      ![window[@"selectedTabID"] isEqualToString:tabID] || !ARCIsCanonicalID(requestID) || !text.length)
    return NO;
  if (![entry[@"findText"] isEqualToString:text]) {
    entry[@"findRequestID"] = nil;
    [tab find:@"" forward:YES];
  }
  entry[@"findRequestID"] = requestID;
  entry[@"findText"] = text;
  [tab find:text forward:forward];
  return YES;
}

- (void)stopFindingInPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return;
  NSMutableDictionary *entry = (NSMutableDictionary *)_privateProbeTabs[tabID];
  entry[@"findRequestID"] = nil;
  entry[@"findText"] = nil;
  [tab find:@"" forward:YES];
  [tab stopFinding];
}

- (NSWindow *)windowForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  NSDictionary *entry = _privateProbeWindows[windowID];
  return [self privateWindowContextOwned:contextID windowID:windowID] ? [entry[@"native"] window] : nil;
}

- (NSView *)hostViewForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  NSDictionary *entry = _privateProbeWindows[windowID];
  return [self privateWindowContextOwned:contextID windowID:windowID] ? [entry[@"native"] hostView] : nil;
}

- (NSView *)viewForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]
    ? tab.view : nil;
}

- (void)privateWindowDidCloseID:(NSString *)windowID {
  NSMutableDictionary *entry = _privateProbeWindows[windowID];
  if (!entry || [entry[@"closed"] boolValue]) return;
  entry[@"closed"] = @YES;
  NSString *contextID = entry[@"contextID"];
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  NSArray<NSString *> *tabIDs = [entry[@"tabIDs"] allObjects];
  NSMutableArray<NSDictionary *> *tabClosures = [NSMutableArray array];
  NSMutableArray<NSString *> *retiredTabIDs = [NSMutableArray array];
  for (NSString *tabID in tabIDs) {
    NSDictionary *tabEntry = _privateProbeTabs[tabID];
    if (tabEntry) [retiredTabIDs addObject:tabID];
    if (tabEntry[@"closeCompletion"])
      [tabClosures addObject:@{@"entry": tabEntry, @"completion": tabEntry[@"closeCompletion"]}];
    [_privateProbeTabs removeObjectForKey:tabID];
    [_privateProbePendingTabs removeObject:tabID];
  }
  id observer = entry[@"observer"];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  for (NSString *origin in [entry[@"cookieOrigins"] copy]) {
    NSDictionary *args = @{@"offTheRecord": @YES, @"origin": origin, @"type": @"cookies", @"value": @"block"};
    [_services call:@"site_settings.set" profileID:context[@"sourceProfileID"] args:args completion:^(NSDictionary *result) {}];
    for (NSMutableDictionary *other in _privateProbeWindows.allValues) {
      if (_privateProbeContexts[other[@"contextID"]][@"profile"] == context[@"profile"])
        [other[@"cookieOrigins"] removeObject:origin];
    }
  }
  [_privateProbeWindows removeObjectForKey:windowID];
  [context[@"windows"] removeObject:windowID];
  if (_closingBrowser && [(NSSet *)context[@"windows"] count] == 0 &&
      [(NSSet *)context[@"pendingWindows"] count] == 0) {
    context[@"finalCloseConfirmedWhileQuitting"] = @YES;
  }
  for (NSString *tabID in retiredTabIDs) {
    if (self.onPrivateTabClosed) self.onPrivateTabClosed(contextID, windowID, tabID);
  }
  for (NSDictionary *closure in tabClosures) {
    void (^closeCompletion)(BOOL) = closure[@"completion"];
    if (closeCompletion) closeCompletion(YES);
  }
  if (self.onPrivateWindowClosed) self.onPrivateWindowClosed(contextID, windowID);
  void (^completion)(BOOL) = entry[@"closeCompletion"];
  if (completion) completion(YES);
}

- (void)closePrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                  completion:(void (^)(BOOL))completion {
  NSMutableDictionary *entry = _privateProbeWindows[windowID];
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  BOOL ownedQuitClose = _closingBrowser && _testing && _probeRoot &&
      ARCProbeRootIsOwned(_probeRoot) && _engine && entry && context &&
      [entry[@"contextID"] isEqualToString:contextID] &&
      [context[@"windows"] containsObject:windowID];
  if ((!_engine || (_closingBrowser && !ownedQuitClose)) || !entry ||
      ![entry[@"contextID"] isEqualToString:contextID] || entry[@"closeCompletion"]) {
    completion(NO);
    return;
  }
  ArdiaCoreWindow *native = entry[@"native"];
  if (!native || !context || ![context[@"windows"] containsObject:windowID]) {
    completion(NO);
    return;
  }
  if ([entry[@"closing"] boolValue]) {
    if (!ownedQuitClose) { completion(NO); return; }
    entry[@"ownerCloseRequestedWhileQuitting"] = @YES;
    entry[@"closeCompletion"] = [completion copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      NSMutableDictionary *current = self->_privateProbeWindows[windowID];
      if (current != entry) return;
      void (^pending)(BOOL) = current[@"closeCompletion"];
      current[@"closeCompletion"] = nil;
      if (pending) pending(NO);
    });
    return;
  }
  entry[@"closing"] = @YES;
  entry[@"ownerCloseRequestedWhileQuitting"] = @(_closingBrowser);
  entry[@"closeCompletion"] = [completion copy];
  [native.window performClose:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSMutableDictionary *current = self->_privateProbeWindows[windowID];
    if (current != entry) return;
    void (^pending)(BOOL) = current[@"closeCompletion"];
    current[@"closeCompletion"] = nil;
    if (pending) pending(NO);
  });
}

- (BOOL)releasePrivateContextID:(NSString *)contextID {
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  BOOL confirmedQuitClose = [context[@"finalCloseConfirmedWhileQuitting"] boolValue];
  if (!_engine || (_closingBrowser && !confirmedQuitClose) || !context ||
      [context[@"windows"] count] != 0) return NO;
  ArdiaCoreProfile *profile = context[@"profile"];
  if (!profile || !profile.offTheRecord ||
      [(NSSet *)context[@"pendingWindows"] count] != 0) return NO;
  NSString *sourceProfileID = context[@"sourceProfileID"];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  if (!source || source.destroyed || source.offTheRecord || _profiles[sourceProfileID] != source) return NO;
  NSMutableDictionary *lease = _privateProbeSourceLeases[sourceProfileID];
  if (!lease || ![lease[@"contextIDs"] containsObject:contextID]) return NO;
  [_privateProbeContexts removeObjectForKey:contextID];
  [lease[@"contextIDs"] removeObject:contextID];
  if (![lease[@"contextIDs"] count] && ![lease[@"pending"] count]) {
    [_privateProbeSourceLeases removeObjectForKey:sourceProfileID];
    if (!profile.destroyed) [_engine releaseProfile:profile];
  }
  return YES;
}

@end

@implementation ARCShaarRuntime (PrivateBrowsing)

- (BOOL)privateContextEnabled {
  return [self privateEngineHandle] != nullptr && !self.isQuitting;
}

- (BOOL)privateIdentityOccupied:(NSString *)identity {
  NSDictionary *state = ARCPrivateShaarState(self);
  return state[@"contexts"][identity] || state[@"windows"][identity] ||
         state[@"tabs"][identity] || [state[@"retired"] containsObject:identity] ||
         [self privateProfileHandleForID:identity] || [self windowForID:identity] ||
         [self windowIDForTabID:identity];
}

- (BOOL)isPrivateIdentity:(NSString *)identity {
  NSDictionary *state = ARCPrivateShaarState(self);
  return state[@"contexts"][identity] || state[@"windows"][identity] ||
         state[@"tabs"][identity];
}

- (void)createPrivateContextID:(NSString *)contextID sourceProfileID:(NSString *)sourceProfileID
                    completion:(void (^)(BOOL, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Private sessions require the UI thread");
  auto profile = [self privateProfileHandleForID:sourceProfileID];
  auto open = PrivateSymbol<decltype(&shaar_private_session_open)>(
      "shaar_private_session_open");
  if (![self privateContextEnabled] || !ARCIsCanonicalID(contextID) ||
      !ARCIsCanonicalID(sourceProfileID) || !profile ||
      [self privateIdentityOccupied:contextID] || !open) {
    completion(NO, ARCBridgeError(@"Invalid private probe context or source profile."));
    return;
  }
  shaar_private_session *session = nullptr;
  shaar_error error = ARCPrivateShaarEmptyError();
  if (open(profile, ARCPrivateShaarBytes(contextID), &session, &error) != SHAAR_OK ||
      !session) {
    completion(NO, ARCBridgeError(@"The private source lease is unavailable."));
    return;
  }
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  state[@"contexts"][contextID] = [@{@"sourceProfileID": sourceProfileID,
    @"session": [NSValue valueWithPointer:session],
    @"windows": [NSMutableSet set]} mutableCopy];
  completion(YES, nil);
}

- (BOOL)privateWindowContextOwned:(NSString *)contextID windowID:(NSString *)windowID {
  NSDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  NSDictionary *window = state[@"windows"][windowID];
  return [self privateContextEnabled] && context && window &&
         [window[@"contextID"] isEqualToString:contextID] &&
         ![window[@"closing"] boolValue] &&
         [context[@"windows"] containsObject:windowID] &&
         [self privateProfileHandleForID:context[@"sourceProfileID"]];
}

- (BOOL)privateTabOwned:(NSString *)tabID windowID:(NSString *)windowID
             contextID:(NSString *)contextID {
  NSDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *tab = state[@"tabs"][tabID];
  NSDictionary *window = state[@"windows"][windowID];
  return [self privateWindowContextOwned:contextID windowID:windowID] && tab &&
         [tab[@"contextID"] isEqualToString:contextID] &&
         [tab[@"windowID"] isEqualToString:windowID] &&
         [window[@"tabs"] containsObject:tabID] && ![tab[@"closing"] boolValue];
}

- (BOOL)openPrivateTabHandleID:(NSString *)tabID windowID:(NSString *)windowID
                      contextID:(NSString *)contextID url:(NSString *)url
                          error:(NSError **)error {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  NSMutableDictionary *window = state[@"windows"][windowID];
  auto open = PrivateSymbol<decltype(&shaar_tab_open)>("shaar_tab_open");
  if (!open || !context || !window) return NO;
  shaar_tab *tab = nullptr;
  shaar_error nativeError = ARCPrivateShaarEmptyError();
  shaar_error_code status = open(PrivateScope(context), PrivateWindow(window),
      ARCPrivateShaarBytes(tabID), ARCPrivateShaarBytes(@"about:blank"), 0,
      &tab, &nativeError);
  if (status != SHAAR_OK || !tab) {
    if (error) *error = ARCBridgeError(@"Chromium could not create the private tab.");
    return NO;
  }
  state[@"tabs"][tabID] = [@{@"contextID": contextID, @"windowID": windowID,
    @"handle": [NSValue valueWithPointer:tab], @"url": @"about:blank",
    @"requestedURL": url} mutableCopy];
  [window[@"tabs"] addObject:tabID];
  if (self.onPrivateTabChanged)
    self.onPrivateTabChanged(contextID, windowID, tabID, @"about:blank", @"", NO, NO, NO);
  [self preparePrivateTabID:tabID windowID:windowID contextID:contextID url:url];
  return YES;
}

- (BOOL)createPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                         tabID:(NSString *)tabID url:(NSString *)url error:(NSError **)error {
  NSAssert(NSThread.isMainThread, @"Private windows require the UI thread");
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSMutableDictionary *context = state[@"contexts"][contextID];
  auto open = PrivateSymbol<decltype(&shaar_window_open)>("shaar_window_open");
  if (!context || !open || !ARCIsCanonicalID(windowID) ||
      !ARCIsCanonicalID(tabID) || [self privateIdentityOccupied:windowID] ||
      [self privateIdentityOccupied:tabID] || ![self privateURLIsAllowed:url] ||
      ![self privateContextEnabled]) {
    if (error) *error = ARCBridgeError(@"Invalid, unknown, closed, or unsupported private navigation.");
    return NO;
  }
  shaar_window *window = nullptr;
  shaar_error nativeError = ARCPrivateShaarEmptyError();
  shaar_error_code status = open([self privateEngineHandle], SHAAR_WINDOW_PRIVATE,
      PrivateScope(context).private_session, ARCPrivateShaarBytes(windowID),
      &window, &nativeError);
  if (status != SHAAR_OK || !window) {
    if (error) *error = ARCBridgeError(@"Chromium could not create the private window.");
    return NO;
  }
  state[@"windows"][windowID] = [@{@"contextID": contextID,
    @"handle": [NSValue valueWithPointer:window], @"tabs": [NSMutableSet set],
    @"closing": @NO} mutableCopy];
  [context[@"windows"] addObject:windowID];
  if (![self openPrivateTabHandleID:tabID windowID:windowID contextID:contextID
                             url:url error:error]) {
    auto close = PrivateSymbol<decltype(&shaar_window_close)>("shaar_window_close");
    if (close) close(window, &nativeError);
    [context[@"windows"] removeObject:windowID];
    [state[@"windows"] removeObjectForKey:windowID];
    return NO;
  }
  if ([self selectPrivateTabID:tabID windowID:windowID contextID:contextID]) return YES;
  auto close = PrivateSymbol<decltype(&shaar_window_close)>("shaar_window_close");
  if (close) close(window, &nativeError);
  [state[@"tabs"] removeObjectForKey:tabID];
  [context[@"windows"] removeObject:windowID];
  [state[@"windows"] removeObjectForKey:windowID];
  if (error) *error = ARCBridgeError(@"Chromium could not create the private tab.");
  return NO;
}

- (BOOL)openPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
               contextID:(NSString *)contextID url:(NSString *)url error:(NSError **)error {
  if (!ARCIsCanonicalID(tabID) || [self privateIdentityOccupied:tabID] ||
      ![self privateWindowContextOwned:contextID windowID:windowID] ||
      ![self privateURLIsAllowed:url]) {
    if (error) *error = ARCBridgeError(@"Invalid private tab owner or unsupported navigation.");
    return NO;
  }
  return [self openPrivateTabHandleID:tabID windowID:windowID
                           contextID:contextID url:url error:error];
}

- (BOOL)selectPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return NO;
  NSDictionary *state = ARCPrivateShaarState(self);
  NSMutableDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  auto attach = PrivateSymbol<decltype(&shaar_tab_view_attach)>(
      "shaar_tab_view_attach");
  if (!attach) return NO;
  shaar_error error = ARCPrivateShaarEmptyError();
  if (attach([self privateEngineHandle], PrivateWindow(window), PrivateTab(tab),
             &error) != SHAAR_OK) return NO;
  window[@"selectedTabID"] = tabID;
  NSDictionary *context = state[@"contexts"][contextID];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
    ARCPrivateShaarSubmit(self, PrivateScope(context), PrivateWindow(window),
        PrivateTab(tab), SHAAR_OP_WINDOW_ACTIVATE_TAB,
        @{@"schemaVersion": @1, @"tabID": tabID},
        ^(NSDictionary *reply) {});
  });
  if (self.onPrivateTabSelected) self.onPrivateTabSelected(contextID, windowID, tabID);
  return YES;
}

- (BOOL)focusPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                contextID:(NSString *)contextID {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return NO;
  NSDictionary *state = ARCPrivateShaarState(self);
  auto focus = PrivateSymbol<decltype(&shaar_tab_view_focus)>("shaar_tab_view_focus");
  if (!focus) return NO;
  shaar_error error = ARCPrivateShaarEmptyError();
  return focus([self privateEngineHandle], PrivateWindow(state[@"windows"][windowID]),
               PrivateTab(state[@"tabs"][tabID]), &error) == SHAAR_OK;
}

- (BOOL)navigatePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                   contextID:(NSString *)contextID url:(NSString *)url {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID] ||
      ![self privateURLIsAllowed:url]) return NO;
  [self preparePrivateTabID:tabID windowID:windowID contextID:contextID url:url];
  return YES;
}

- (BOOL)privateTabOperation:(shaar_operation)operation tabID:(NSString *)tabID
                  windowID:(NSString *)windowID contextID:(NSString *)contextID
                   payload:(NSDictionary *)payload {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return NO;
  NSDictionary *state = ARCPrivateShaarState(self);
  return ARCPrivateShaarSubmit(self, PrivateScope(state[@"contexts"][contextID]),
      PrivateWindow(state[@"windows"][windowID]), PrivateTab(state[@"tabs"][tabID]),
      operation, payload, ^(NSDictionary *reply) {});
}

- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID {
  return [self privateTabOperation:SHAAR_OP_TAB_RELOAD tabID:tabID windowID:windowID
                        contextID:contextID payload:@{@"schemaVersion": @1,
                                                      @"mode": @"normal"}];
}
- (BOOL)goBackPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID {
  NSDictionary *tab = ARCPrivateShaarState(self)[@"tabs"][tabID];
  if (![tab[@"canGoBack"] boolValue]) return NO;
  return [self privateTabOperation:SHAAR_OP_TAB_GO tabID:tabID windowID:windowID
                        contextID:contextID payload:@{@"schemaVersion": @1,
                                                      @"direction": @"back"}];
}
- (BOOL)goForwardPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                    contextID:(NSString *)contextID {
  NSDictionary *tab = ARCPrivateShaarState(self)[@"tabs"][tabID];
  if (![tab[@"canGoForward"] boolValue]) return NO;
  return [self privateTabOperation:SHAAR_OP_TAB_GO tabID:tabID windowID:windowID
                        contextID:contextID payload:@{@"schemaVersion": @1,
                                                      @"direction": @"forward"}];
}

- (void)closePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                contextID:(NSString *)contextID completion:(void (^)(BOOL))completion {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSMutableDictionary *entry = state[@"tabs"][tabID];
  auto close = PrivateSymbol<decltype(&shaar_tab_close)>("shaar_tab_close");
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID] ||
      entry[@"completion"] || !close) { completion(NO); return; }
  entry[@"closing"] = @YES;
  entry[@"completion"] = [completion copy];
  shaar_error error = ARCPrivateShaarEmptyError();
  if (close(PrivateTab(entry), &error) == SHAAR_OK) {
    __weak ARCShaarRuntime *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
      ARCShaarRuntime *owner = weakSelf;
      if (!owner) return;
      if (ARCPrivateShaarState(owner)[@"tabs"][tabID] != entry) return;
      void (^pending)(BOOL) = entry[@"completion"];
      entry[@"completion"] = nil;
      entry[@"closing"] = @NO;
      if (pending) pending(NO);
    });
    return;
  }
  entry[@"closing"] = @NO;
  entry[@"completion"] = nil;
  completion(NO);
}

- (NSWindow *)windowForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  if (![self privateWindowContextOwned:contextID windowID:windowID]) return nil;
  auto native = PrivateSymbol<decltype(&shaar_window_native_window)>(
      "shaar_window_native_window");
  NSDictionary *window = ARCPrivateShaarState(self)[@"windows"][windowID];
  return native ? (__bridge NSWindow *)native(PrivateWindow(window)) : nil;
}

- (NSView *)hostViewForPrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID {
  if (![self privateWindowContextOwned:contextID windowID:windowID]) return nil;
  auto host = PrivateSymbol<decltype(&shaar_window_host_view)>("shaar_window_host_view");
  if (!host) return nil;
  NSMutableDictionary *window = ARCPrivateShaarState(self)[@"windows"][windowID];
  NSView *view = (__bridge NSView *)host(PrivateWindow(window));
  if (!view || window[@"resizeObserver"]) return view;
  view.postsFrameChangedNotifications = YES;
  __weak ARCShaarRuntime *weakSelf = self;
  window[@"resizeObserver"] = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification object:view
                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
    ARCShaarRuntime *owner = weakSelf;
    if (!owner) return;
    NSDictionary *current = ARCPrivateShaarState(owner)[@"windows"][windowID];
    auto resize = PrivateSymbol<decltype(&shaar_window_host_resize)>(
        "shaar_window_host_resize");
    if (!current || !resize) return;
    NSSize size = [(NSView *)notification.object bounds].size;
    shaar_error error = ARCPrivateShaarEmptyError();
    resize([owner privateEngineHandle], PrivateWindow(current),
           size.width, size.height, &error);
  }];
  return view;
}

- (NSView *)viewForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                     contextID:(NSString *)contextID {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return nil;
  auto host = PrivateSymbol<decltype(&shaar_tab_host_view)>("shaar_tab_host_view");
  NSDictionary *tab = ARCPrivateShaarState(self)[@"tabs"][tabID];
  return host ? (__bridge NSView *)host(PrivateTab(tab)) : nil;
}

- (void)closePrivateWindowID:(NSString *)windowID contextID:(NSString *)contextID
                  completion:(void (^)(BOOL))completion {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSMutableDictionary *window = state[@"windows"][windowID];
  auto close = PrivateSymbol<decltype(&shaar_window_close)>("shaar_window_close");
  if (![self privateWindowContextOwned:contextID windowID:windowID] ||
      window[@"completion"] || !close) { completion(NO); return; }
  window[@"closing"] = @YES;
  window[@"completion"] = [completion copy];
  shaar_error error = ARCPrivateShaarEmptyError();
  if (close(PrivateWindow(window), &error) == SHAAR_OK) {
    __weak ARCShaarRuntime *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
      ARCShaarRuntime *owner = weakSelf;
      if (!owner) return;
      if (ARCPrivateShaarState(owner)[@"windows"][windowID] != window) return;
      void (^pending)(BOOL) = window[@"completion"];
      window[@"completion"] = nil;
      window[@"closing"] = @NO;
      if (pending) pending(NO);
    });
    return;
  }
  window[@"closing"] = @NO;
  window[@"completion"] = nil;
  completion(NO);
}

- (BOOL)releasePrivateContextID:(NSString *)contextID {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  auto close = PrivateSymbol<decltype(&shaar_private_session_close)>(
      "shaar_private_session_close");
  if (!context || [context[@"windows"] count] || !close) return NO;
  shaar_error error = ARCPrivateShaarEmptyError();
  if (close(PrivateScope(context).private_session, &error) != SHAAR_OK) return NO;
  [state[@"contexts"] removeObjectForKey:contextID];
  [state[@"retired"] addObject:contextID];
  return YES;
}

- (void)finishPrivateTabID:(NSString *)tabID {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *entry = state[@"tabs"][tabID];
  if (!entry) return;
  NSString *contextID = entry[@"contextID"];
  NSString *windowID = entry[@"windowID"];
  [state[@"windows"][windowID][@"tabs"] removeObject:tabID];
  [state[@"tabs"] removeObjectForKey:tabID];
  [state[@"retired"] addObject:tabID];
  if (self.onPrivateTabClosed) self.onPrivateTabClosed(contextID, windowID, tabID);
  void (^completion)(BOOL) = entry[@"completion"];
  if (completion) completion(YES);
}

- (void)finishPrivateWindowID:(NSString *)windowID {
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *entry = state[@"windows"][windowID];
  if (!entry) return;
  NSString *contextID = entry[@"contextID"];
  [self revokePrivateCookiesForWindowID:windowID];
  for (NSString *tabID in [entry[@"tabs"] allObjects]) [self finishPrivateTabID:tabID];
  id observer = entry[@"resizeObserver"];
  if (observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
  [state[@"contexts"][contextID][@"windows"] removeObject:windowID];
  [state[@"windows"] removeObjectForKey:windowID];
  [state[@"retired"] addObject:windowID];
  if (self.onPrivateWindowClosed) self.onPrivateWindowClosed(contextID, windowID);
  void (^completion)(BOOL) = entry[@"completion"];
  if (completion) completion(YES);
}

- (void)receivePrivateEvent:(const shaar_event *)event payload:(NSDictionary *)payload {
  NSString *contextID = PrivateString(event->session_id);
  NSString *profileID = PrivateString(event->profile_id);
  NSString *windowID = PrivateString(event->window_id);
  NSString *tabID = PrivateString(event->tab_id);
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  if (!context ||
      [context[@"sourceProfileID"] caseInsensitiveCompare:profileID] != NSOrderedSame)
    return;
  if (event->kind == SHAAR_EVENT_TAB && [payload[@"kind"] isEqual:@"closed"]) {
    if ([state[@"tabs"][tabID][@"contextID"] isEqual:contextID])
      [self finishPrivateTabID:tabID];
    return;
  }
  if (event->kind == SHAAR_EVENT_WINDOW && [payload[@"kind"] isEqual:@"closed"]) {
    if ([state[@"windows"][windowID][@"contextID"] isEqual:contextID])
      [self finishPrivateWindowID:windowID];
    return;
  }
  if (event->kind != SHAAR_EVENT_NAVIGATION ||
      ![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
  NSMutableDictionary *tab = state[@"tabs"][tabID];
  NSString *url = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : tab[@"url"];
  tab[@"url"] = url ?: @"about:blank";
  tab[@"canGoBack"] = payload[@"canGoBack"] ?: @NO;
  tab[@"canGoForward"] = payload[@"canGoForward"] ?: @NO;
  if (self.onPrivateTabChanged)
    self.onPrivateTabChanged(contextID, windowID, tabID, tab[@"url"],
      [payload[@"title"] isKindOfClass:NSString.class] ? payload[@"title"] : @"",
      [payload[@"loading"] boolValue], [payload[@"canGoBack"] boolValue],
      [payload[@"canGoForward"] boolValue]);
  if (payload[@"failure"] && self.onPrivateNavigationFailed)
    self.onPrivateNavigationFailed(contextID, windowID, tabID,
      @"Private navigation failed.");
}

@end
