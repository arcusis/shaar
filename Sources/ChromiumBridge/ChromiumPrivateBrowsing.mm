// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumProbeRoot.h"

@implementation ARCChromiumRuntime (PrivateBrowsing)

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

- (BOOL)privateProbeIdentityIsAvailable:(NSString *)identity {
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
      !source || source.destroyed || source.offTheRecord ||
      ![self privateProbeIdentityIsAvailable:contextID]) {
    completion(NO, ARCBridgeError(@"Invalid private probe context or source profile."));
    return;
  }
  if (_privateProbePendingContexts[contextID]) {
    completion(NO, ARCBridgeError(@"Private probe context identity is already pending."));
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
        if (valid) current[@"profile"] = privateProfile;
        NSDictionary *pending = [current[@"pending"] copy];
        [current[@"pending"] removeAllObjects];
        NSMutableSet<NSString *> *registered = [NSMutableSet set];
        for (NSString *pendingID in pending) {
          [self->_privateProbePendingContexts removeObjectForKey:pendingID];
          if (valid && [self privateContextEnabled] &&
              [self privateProbeIdentityIsAvailable:pendingID]) {
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
          if (valid && !privateProfile.destroyed) [self->_engine releaseProfile:privateProfile];
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
      ![self privateProbeIdentityIsAvailable:windowID] ||
      ![self privateProbeIdentityIsAvailable:tabID] ||
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
  ArdiaCoreTab *tab = [native openTab:url profile:profile foreground:YES];
  if (!tab || !native.hostView || !tab.view || !creationCurrent()) {
    [tab closeNow];
    [native close];
    [context[@"pendingWindows"] removeObject:windowID];
    [_privateProbePendingWindows removeObject:windowID];
    [_privateProbePendingTabs removeObject:tabID];
    if (error) *error = ARCBridgeError(@"Chromium could not create the private tab.");
    return NO;
  }
  tab.view.frame = native.hostView.bounds;
  tab.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [native.hostView addSubview:tab.view];
  [tab loadURL:url];
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
      [weakSelf privateProbeWindowDidCloseID:windowID];
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
      [windowEntry[@"closing"] boolValue] || !native || ![self privateProbeIdentityIsAvailable:tabID] ||
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
      ![self privateProbeIdentityIsAvailable:tabID];
  };
  if (windowEntry[@"pendingTabs"] == nil) windowEntry[@"pendingTabs"] = [NSMutableSet set];
  if ([windowEntry[@"pendingTabs"] containsObject:tabID]) return NO;
  [windowEntry[@"pendingTabs"] addObject:tabID];
  [_privateProbePendingTabs addObject:tabID];
  ArdiaCoreTab *tab = [native openTab:url profile:profile foreground:NO];
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
  tab.view.frame = native.hostView.bounds;
  tab.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [native.hostView addSubview:tab.view];
  tab.delegate = self;
  tab.view.hidden = YES;
  if (!current() || _privateProbeTabs[tabID] != entry) {
    [tab closeNow];
    if (error) *error = ARCBridgeError(@"Private tab owner changed during creation.");
    return NO;
  }
  [tab loadURL:url];
  if (!current() || _privateProbeTabs[tabID] != entry) {
    [tab closeNow];
    if (error) *error = ARCBridgeError(@"Private tab owner changed during navigation start.");
    return NO;
  }
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
  [tab loadURL:url];
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil];
}

- (BOOL)focusPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  [tab focus];
  return [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil];
}

- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID contextID:(NSString *)contextID {
  ArdiaCoreTab *tab = nil;
  if (![self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:nil]) return NO;
  [tab reload];
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

- (void)privateProbeWindowDidCloseID:(NSString *)windowID {
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
