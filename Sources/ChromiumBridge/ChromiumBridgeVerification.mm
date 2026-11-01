// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumProbeRoot.h"
#include <cmath>

static void ClickProbeTarget(ArdiaCoreTab *tab, NSString *expression, BOOL (^current)(void),
                             void (^completion)(BOOL)) {
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression": expression, @"returnByValue": @YES}
               timeout:5 completion:^(NSDictionary *result, NSString *error) {
    NSDictionary *point = result[@"result"][@"value"];
    if (error || ![point isKindOfClass:NSDictionary.class] || !current() ||
        ![point[@"x"] isKindOfClass:NSNumber.class] || ![point[@"y"] isKindOfClass:NSNumber.class] ||
        !std::isfinite([point[@"x"] doubleValue]) || !std::isfinite([point[@"y"] doubleValue])) {
      completion(NO);
      return;
    }
    NSDictionary *press = @{@"type": @"mousePressed", @"x": point[@"x"], @"y": point[@"y"],
                             @"button": @"left", @"buttons": @1, @"clickCount": @1};
    [tab devToolsCall:@"Input.dispatchMouseEvent" params:press timeout:5
            completion:^(NSDictionary *ignored, NSString *pressError) {
      if (pressError || !current()) { completion(NO); return; }
      NSDictionary *release = @{@"type": @"mouseReleased", @"x": point[@"x"], @"y": point[@"y"],
                                 @"button": @"left", @"buttons": @0, @"clickCount": @1};
      [tab devToolsCall:@"Input.dispatchMouseEvent" params:release timeout:5
              completion:^(NSDictionary *ignoredRelease, NSString *releaseError) {
        completion(releaseError == nil && current());
      }];
    }];
  }];
}

static NSString *ProbeButtonExpression(NSString *literal) {
  return [NSString stringWithFormat:
    @"(()=>{const title=%@;const excluded=e=>{for(let n=e;n&&n.nodeType===1;n=n.parentElement){"
     "if(n.hidden||n.inert||n.getAttribute('aria-hidden')?.toLowerCase()==='true')return true;"
     "const s=getComputedStyle(n);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||s.opacity==='0')return true;}return false;};"
     "const text=e=>{const w=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);let out='',n;"
     "while((n=w.nextNode()))if(!excluded(n.parentElement))out+=' '+n.nodeValue;return out.trim().replace(/\\s+/g,' ');};"
     "const label=e=>(e.getAttribute('aria-label')||text(e)).trim().replace(/\\s+/g,' ');"
     "const candidates=[...document.querySelectorAll('button,a,[role=button]')],exact=candidates.filter(e=>label(e)===title),"
     "visible=exact.filter(e=>!excluded(e)),sized=visible.filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0;}),"
     "eligible=sized.filter(e=>!e.disabled&&e.getAttribute('aria-disabled')?.toLowerCase()!=='true');"
     "const hit=(e,x,y)=>{const top=document.elementFromPoint(x,y);return !!top&&(top===e||e.contains(top));};"
     "const point=e=>{const r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return null;const x=r.x+r.width/2,y=r.y+r.height/2;"
     "if(x>=0&&y>=0&&x<innerWidth&&y<innerHeight&&hit(e,x,y))return {x,y};const l=Math.max(0,r.left),t=Math.max(0,r.top),"
     "rr=Math.min(innerWidth,r.right),bb=Math.min(innerHeight,r.bottom);if(rr<=l||bb<=t)return null;"
     "for(const fx of [.1,.5,.9])for(const fy of [.1,.5,.9]){const px=l+(rr-l)*fx,py=t+(bb-t)*fy;if(hit(e,px,py))return {x:px,y:py};}return null;};"
     "if(eligible.length!==1)return null;const button=eligible[0];let visiblePoint=point(button);if(!visiblePoint){button.scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});visiblePoint=point(button);}return visiblePoint;})()",
    literal];
}

static BOOL ProbeViewIsVisibleInWindow(NSView *view, NSWindow *window) {
  if (!view || !window || view.window != window) return NO;
  for (NSView *ancestor = view; ancestor; ancestor = ancestor.superview) {
    if (ancestor.hidden) return NO;
  }
  return YES;
}

@implementation ARCChromiumRuntime (Verification)

- (BOOL)inspectProbeElementInTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  NSURLComponents *url = [NSURLComponents componentsWithString:tab.url ?: @""];
  if (!_testing || !_probeRoot || !ARCProbeRootIsOwned(_probeRoot) || !tab ||
      ![url.scheme isEqualToString:@"http"] ||
      ![@[@"127.0.0.1", @"localhost"] containsObject:url.host.lowercaseString] ||
      ![self isSelectedTabID:tabID]) return NO;
  _probeInspectTabID = [tabID copy];
  _probeInspectFound = NO;
  _probeInspectAudit = [@{@"pressed": @NO, @"released": @NO, @"menuSeen": @NO} mutableCopy];
  [tab devToolsCall:@"Input.dispatchMouseEvent"
            params:@{@"type": @"mousePressed", @"x": @80, @"y": @80,
                     @"button": @"right", @"buttons": @2, @"clickCount": @1}
           timeout:5 completion:^(NSDictionary *result, NSString *error) {
    self->_probeInspectAudit[@"pressed"] = @(error == nil);
    if (error) self->_probeInspectAudit[@"pressError"] = error;
    [tab devToolsCall:@"Input.dispatchMouseEvent"
              params:@{@"type": @"mouseReleased", @"x": @80, @"y": @80,
                       @"button": @"right", @"buttons": @0, @"clickCount": @1}
             timeout:5 completion:^(NSDictionary *released, NSString *releaseError) {
      self->_probeInspectAudit[@"released"] = @(releaseError == nil);
      if (releaseError) self->_probeInspectAudit[@"releaseError"] = releaseError;
    }];
  }];
  return YES;
}

- (BOOL)probeInspectFound { return _testing && _probeInspectFound; }
- (NSDictionary *)probeInspectAudit { return _testing ? [_probeInspectAudit copy] : nil; }

// The engine offers this hook only in background mode. Production keeps Chromium's native
// context menu, including its Inspect command and the original clicked-node coordinates.
- (NSDictionary *)tab:(ArdiaCoreTab *)tab runContextMenu:(NSDictionary *)menu {
  NSString *identity = [self identityForTab:tab];
  if (!_testing || !identity || ![_probeInspectTabID isEqualToString:identity]) return nil;
  _probeInspectTabID = nil;
  _probeInspectAudit[@"menuSeen"] = @YES;
  _probeInspectAudit[@"items"] = menu[@"items"] ?: @[];
  for (NSDictionary *item in menu[@"items"]) {
    NSString *label = [item[@"label"] isKindOfClass:NSString.class] ? item[@"label"] : @"";
    label = [label stringByReplacingOccurrencesOfString:@"&" withString:@""];
    if ([label isEqualToString:@"Inspect"] && [item[@"enabled"] boolValue] &&
        [item[@"id"] isKindOfClass:NSNumber.class]) {
      _probeInspectFound = YES;
      _probeInspectAudit[@"selected"] = item[@"id"];
      return @{@"command": item[@"id"]};
    }
  }
  return nil;
}

- (BOOL)privateProbeEnabled {
  return _testing && _probeRoot && ARCProbeRootIsOwned(_probeRoot) && !_closingBrowser;
}

- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString *))completion {
  NSDictionary *entry = _privateProbeTabs[tabID];
  ArdiaCoreTab *tab = entry[@"tab"];
  NSMutableDictionary *context = _privateProbeContexts[entry[@"contextID"]];
  if (![self privateProbeEnabled] || !tab || tab.closed || !context ||
      !tab.profile.offTheRecord || tab.profile != context[@"profile"]) {
    if (context) context[@"privateEvaluationRejected"] = @YES;
    completion(nil);
    return;
  }
  NSMutableDictionary *capturedContext = context;
  NSMutableDictionary *lease = _privateProbeSourceLeases[context[@"sourceProfileID"]];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  [self evaluateTab:tab script:script completion:^(NSString *json) {
    NSDictionary *current = self->_privateProbeTabs[tabID];
    BOOL currentOwner = current == entry && self->_privateProbeContexts[entry[@"contextID"]] == capturedContext &&
      self->_privateProbeSourceLeases[capturedContext[@"sourceProfileID"]] == lease &&
      self->_profiles[capturedContext[@"sourceProfileID"]] == source && !source.destroyed &&
      capturedContext[@"profile"] == tab.profile && !tab.closed;
    if (!currentOwner) capturedContext[@"privateEvaluationStale"] = @YES;
    else if (json) capturedContext[@"privateEvaluationSucceeded"] = @YES;
    else capturedContext[@"privateEvaluationTimedOut"] = @YES;
    completion(currentOwner ? json : nil);
  }];
}

- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID {
  NSMutableDictionary *entry = _privateProbeWindows[windowID];
  if (![self privateProbeEnabled] || !entry || [entry[@"closing"] boolValue]) return NO;
  [_privateProbeCancelledCloses addObject:windowID];
  [((ArdiaCoreWindow *)entry[@"native"]).window performClose:nil];
  NSString *tabID = [entry[@"tabIDs"] anyObject];
  NSDictionary *tabEntry = _privateProbeTabs[tabID];
  return _privateProbeWindows[windowID] == entry && ![entry[@"closing"] boolValue] &&
    tabEntry && ![tabEntry[@"tab"] closed];
}

- (NSDictionary *)privateProbeAuditForContextID:(NSString *)contextID {
  NSMutableDictionary *context = _privateProbeContexts[contextID];
  ArdiaCoreProfile *source = context[@"sourceProfile"];
  ArdiaCoreProfile *profile = context[@"profile"];
  BOOL ownedTestingRoot = _testing && _probeRoot && ARCProbeRootIsOwned(_probeRoot) && _engine;
  if (!ownedTestingRoot || !context || !source || !profile) return nil;
  NSUInteger tabCount = 0;
  BOOL allHidden = YES;
  BOOL allWindowsNativeWindowsAlive = YES;
  BOOL allTabsLoaded = YES;
  BOOL allTabsAuthoredLoopbackURL = YES;
  BOOL anyTabLoading = NO;
  BOOL allTabsInNativeProfileBrowser = YES;
  BOOL allTabsAttachedToHostView = YES;
  BOOL allWindowsUsePrivateActiveProfile = YES;
  BOOL allWindowsDisplayOwnedWebContents = YES;
  NSUInteger visibleNativeViewportCount = 0;
  for (NSString *windowID in context[@"windows"]) {
    NSMutableDictionary *window = _privateProbeWindows[windowID];
    ArdiaCoreWindow *nativeWindowObject = window[@"native"];
    NSUInteger visiblePrivateViews = 0;
    if (nativeWindowObject.activeProfile != profile) allWindowsUsePrivateActiveProfile = NO;
    for (NSString *tabID in window[@"tabIDs"]) {
      ArdiaCoreTab *tab = _privateProbeTabs[tabID][@"tab"];
      NSURL *tabURL = [NSURL URLWithString:tab.url ?: @""];
      tabCount++;
      if (!tab || ![[nativeWindowObject tabsForProfile:profile] containsObject:tab])
        allTabsInNativeProfileBrowser = NO;
      if (!tab.view || tab.view.superview != nativeWindowObject.hostView)
        allTabsAttachedToHostView = NO;
      BOOL selected = [window[@"selectedTabID"] isEqualToString:tabID];
      if (tab.view && !tab.view.hidden && tab.view.window == nativeWindowObject.window) visiblePrivateViews++;
      if (selected && (!tab.view || tab.view.hidden || tab.view.window != nativeWindowObject.window))
        allWindowsDisplayOwnedWebContents = NO;
      BOOL loopback = [tabURL.host isEqualToString:@"127.0.0.1"];
      if (!tab || tab.closed || tab.loading || !loopback) allTabsLoaded = NO;
      if (!loopback) allTabsAuthoredLoopbackURL = NO;
      if (tab.loading) anyTabLoading = YES;
    }
    visibleNativeViewportCount += visiblePrivateViews;
    NSWindow *nativeWindow = [window[@"native"] window];
    if (!nativeWindow) allWindowsNativeWindowsAlive = NO;
    if (visiblePrivateViews != 1) allWindowsDisplayOwnedWebContents = NO;
    if (!nativeWindow || nativeWindow.isVisible) allHidden = NO;
  }
  NSString *sourceProfileID = context[@"sourceProfileID"];
  NSDictionary *lease = _privateProbeSourceLeases[sourceProfileID];
  return @{@"sourceIsRegular": @(!source.destroyed && !source.offTheRecord),
           @"contextIsPrivate": @(!profile.destroyed && profile.offTheRecord),
           @"contextDistinct": @(profile != source),
           @"windowCount": @([context[@"windows"] count]), @"tabCount": @(tabCount),
           @"allWindowsNativeWindowsAlive": @(allWindowsNativeWindowsAlive),
           @"allWindowsHidden": @(allHidden), @"allTabsLoaded": @(allTabsLoaded),
           @"allTabsAuthoredLoopbackURL": @(allTabsAuthoredLoopbackURL),
           @"anyTabLoading": @(anyTabLoading),
           @"allTabsInNativeProfileBrowser": @(allTabsInNativeProfileBrowser),
           @"allTabsAttachedToHostView": @(allTabsAttachedToHostView),
           @"allWindowsUsePrivateActiveProfile": @(allWindowsUsePrivateActiveProfile),
           @"allWindowsDisplayOwnedWebContents": @(allWindowsDisplayOwnedWebContents),
           @"visibleNativeViewportCount": @(visibleNativeViewportCount),
           @"pendingWindowCount": @([(NSSet *)context[@"pendingWindows"] count]),
           @"pendingReleaseRejected": context[@"pendingReleaseRejected"] ?: @NO,
           @"sourceLeaseOwnsContext": @([lease[@"contextIDs"] containsObject:contextID]),
           @"privateEvaluationRejected": context[@"privateEvaluationRejected"] ?: @NO,
           @"privateEvaluationStale": context[@"privateEvaluationStale"] ?: @NO,
           @"privateEvaluationSucceeded": context[@"privateEvaluationSucceeded"] ?: @NO,
           @"privateEvaluationTimedOut": context[@"privateEvaluationTimedOut"] ?: @NO,
           @"privateQuitDialogCancelResult": context[@"privateQuitDialogCancelResult"] ?: @"not-attempted",
           @"profileToken": [NSString stringWithFormat:@"%p", profile],
           @"profileAlive": @(!profile.destroyed),
           @"noPendingFactory": @([(NSDictionary *)lease[@"pending"] count] == 0)};
}

- (void)capturePrivateProbeTabID:(NSString *)tabID windowID:(NSString *)windowID
                       contextID:(NSString *)contextID
                      completion:(void (^)(NSData *, NSString *))completion {
  ArdiaCoreTab *tab = nil;
  ArdiaCoreWindow *nativeWindow = nil;
  NSMutableDictionary *window = _privateProbeWindows[windowID];
  BOOL valid = [self privateProbeEnabled] &&
      [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:&tab window:&nativeWindow] &&
      [window[@"selectedTabID"] isEqualToString:tabID] && ![window[@"closing"] boolValue] &&
      !tab.loading && tab.profile.offTheRecord && tab.view &&
      (tab.view == nativeWindow.hostView || [tab.view isDescendantOf:nativeWindow.hostView]) &&
      ProbeViewIsVisibleInWindow(tab.view, nativeWindow.window);
  NSURL *url = [NSURL URLWithString:tab.url ?: @""];
  valid = valid && [url.scheme isEqualToString:@"http"] &&
      [@[@"127.0.0.1", @"localhost"] containsObject:url.host.lowercaseString ?: @""];
  if (!valid) { completion(nil, @"private-owner-rejected"); return; }
  NSDictionary *capturedEntry = _privateProbeTabs[tabID];
  [self captureProbeTab:tab diagnosticCompletion:^(NSData *data, NSString *error) {
    BOOL current = self->_privateProbeTabs[tabID] == capturedEntry &&
        [self privateOwnerForTabID:tabID windowID:windowID contextID:contextID tab:nil window:nil] &&
        [window[@"selectedTabID"] isEqualToString:tabID] && !tab.closed && !tab.loading;
    completion(current ? data : nil, !current ? @"private-owner-stale" : error);
  }];
}

- (NSDictionary *)normalProbeSelectionAuditForTabID:(NSString *)tabID {
  if (![self privateProbeEnabled]) return @{};
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  NSView *view = tab.view;
  NSWindow *window = state.native.window;
  __block NSUInteger visibleTabViewCount = 0;
  [_tabs enumerateKeysAndObjectsUsingBlock:^(NSString *identity, ArdiaCoreTab *ownedTab, BOOL *stop) {
    if (ownedTab.view && ProbeViewIsVisibleInWindow(ownedTab.view, window)) visibleTabViewCount++;
  }];
  BOOL primaryWindow = state && [state.identity isEqualToString:_primaryWindowID];
  BOOL selectedID = state && [state.selectedTabID isEqualToString:tabID];
  BOOL activeProfile = state && tab && state.native.activeProfile == tab.profile;
  BOOL liveTab = tab && !tab.closed;
  BOOL nativeProfileOwnsTab = state && tab &&
    [[state.native tabsForProfile:tab.profile] containsObject:tab];
  BOOL selected = primaryWindow && selectedID && activeProfile && liveTab && nativeProfileOwnsTab &&
    !state.closed && !state.closing && !_closingBrowser;
  BOOL attached = selected && view && state.native.hostView &&
    (view == state.native.hostView || [view isDescendantOf:state.native.hostView]);
  BOOL visible = selected && ProbeViewIsVisibleInWindow(view, window);
  BOOL displayed = visible && attached && visibleTabViewCount == 1;
  return @{@"selectedNativeTab": @(selected), @"displayedNativeWebContents": @(displayed),
           @"primaryWindow": @(primaryWindow), @"selectedID": @(selectedID),
           @"activeProfile": @(activeProfile), @"liveTab": @(liveTab),
           @"nativeProfileOwnsTab": @(nativeProfileOwnsTab),
           @"selectedViewAttached": @(attached), @"selectedViewVisible": @(visible),
           @"visibleNativeViewCount": @(visibleTabViewCount),
           @"nativeTabToken": tab ? [NSString stringWithFormat:@"%p", tab] : @"missing"};
}

- (NSDictionary *)privateQuitCDPHoldAuditForTabID:(NSString *)tabID {
  if (!_testing || !_probeRoot || !ARCProbeRootIsOwned(_probeRoot)) return nil;
  NSMutableDictionary *owner = (NSMutableDictionary *)_privateQuitProbeTabs[tabID];
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  if (!owner || !tab || owner[@"tab"] != tab || tab.closed ||
      ![owner[@"windowID"] isEqualToString:_primaryWindowID] ||
      ![state.identity isEqualToString:_primaryWindowID]) return nil;
  return @{@"holdCommandPending": owner[@"holdCommandPending"] ?: @NO,
           @"holdConfirmedPending": owner[@"holdConfirmedPending"] ?: @NO,
           @"selectedNormalTab": @([state.selectedTabID isEqualToString:tabID])};
}

- (void)preparePrivateQuitCancellationProbeTabID:(NSString *)tabID
                                      completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  NSURLComponents *url = [NSURLComponents componentsWithString:tab.url ?: @""];
  NSString *host = url.host.lowercaseString ?: @"";
  BOOL ownedLoopback = _testing && _probeRoot && ARCProbeRootIsOwned(_probeRoot) &&
      [url.scheme.lowercaseString isEqualToString:@"http"] &&
      [@[@"127.0.0.1", @"localhost"] containsObject:host];
  BOOL valid = ownedLoopback && !_closingBrowser && _engine && tab && !tab.closed &&
      !tab.profile.offTheRecord && state && [state.identity isEqualToString:_primaryWindowID] &&
      [state.selectedTabID isEqualToString:tabID] && _privateProbeContexts.count > 0;
  if (!valid) { completion(NO); return; }
  NSString *event = [@"arcusis-private-quit-cdp-" stringByAppendingString:NSUUID.UUID.UUIDString];
  NSMutableDictionary *owner = [@{@"tab": tab, @"windowID": state.identity, @"event": event,
                                  @"holdCommandPending": @YES,
                                  @"holdConfirmedPending": @NO,
                                  @"releaseStarted": @NO} mutableCopy];
  _privateQuitProbeTabs[tabID] = owner;
  NSString *expression = [NSString stringWithFormat:
    @"(()=>{const key='%@';const holds=window.__arcusisPrivateQuitCDPHolds||(window.__arcusisPrivateQuitCDPHolds=Object.create(null));"
     "holds[key]={started:true,timedOut:false};return new Promise(resolve=>{const timer=setTimeout(()=>{holds[key].timedOut=true;resolve(true)},30000);"
     "addEventListener(key,()=>{clearTimeout(timer);delete holds[key];resolve(true)},{once:true});});})()", event];
  [tab devToolsCall:@"Runtime.evaluate"
             params:@{@"expression": expression, @"awaitPromise": @YES}
            timeout:35 completion:^(NSDictionary *holdResult, NSString *holdError) {
    NSMutableDictionary *currentOwner = (NSMutableDictionary *)self->_privateQuitProbeTabs[tabID];
    if (currentOwner == owner) currentOwner[@"holdCommandPending"] = @NO;
    if (currentOwner == owner) {
      if (holdError || self->_tabs[tabID] != tab || tab.closed)
        currentOwner[@"holdConfirmedPending"] = @NO;
      [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {}];
    }
  }];
  [tab devToolsCall:@"Page.enable" params:@{} timeout:5
         completion:^(NSDictionary *result, NSString *error) {
    BOOL current = self->_privateQuitProbeTabs[tabID] == owner &&
        self->_tabs[tabID] == tab && !tab.closed;
    if (error || !current) {
      if (self->_privateQuitProbeTabs[tabID] == owner)
        [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {}];
      completion(NO);
    } else {
      NSString *verify = [NSString stringWithFormat:
        @"(()=>{const holds=window.__arcusisPrivateQuitCDPHolds;return holds&&holds['%@']||null})()", event];
      [tab devToolsCall:@"Runtime.evaluate"
                 params:@{@"expression": verify, @"returnByValue": @YES}
                timeout:5 completion:^(NSDictionary *verifyResult, NSString *verifyError) {
        NSMutableDictionary *verifiedOwner = (NSMutableDictionary *)self->_privateQuitProbeTabs[tabID];
        id holdState = verifyResult[@"result"][@"value"];
        BOOL pending = !verifyError && verifiedOwner == owner &&
            self->_tabs[tabID] == tab && !tab.closed &&
            [holdState isKindOfClass:NSDictionary.class] &&
            [holdState[@"started"] boolValue] && ![holdState[@"timedOut"] boolValue] &&
            [verifiedOwner[@"holdCommandPending"] boolValue];
        verifiedOwner[@"holdConfirmedPending"] = @(pending);
        if (!pending && verifiedOwner == owner)
          [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {}];
        completion(pending);
      }];
    }
  }];
}

- (void)endPrivateQuitCDPHoldForTabID:(NSString *)tabID
                                  tab:(ArdiaCoreTab *)tab
                           completion:(void (^)(BOOL))completion {
  NSDictionary *owner = _privateQuitProbeTabs[tabID];
  NSString *event = owner[@"event"];
  if (!owner || owner[@"tab"] != tab || !event || _tabs[tabID] != tab || tab.closed) {
    completion(NO);
    return;
  }
  if ([owner[@"releaseStarted"] boolValue]) { completion(NO); return; }
  ((NSMutableDictionary *)owner)[@"releaseStarted"] = @YES;
  NSString *expression = [NSString stringWithFormat:@"dispatchEvent(new Event('%@'))", event];
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression": expression}
           timeout:5 completion:^(NSDictionary *result, NSString *error) {
    BOOL current = self->_privateQuitProbeTabs[tabID] == owner &&
        self->_tabs[tabID] == tab && !tab.closed;
    if (!current) { completion(NO); return; }
    [tab devToolsCall:@"Page.disable" params:@{} timeout:5
           completion:^(NSDictionary *ignored, NSString *disableError) {
      BOOL stillCurrent = self->_privateQuitProbeTabs[tabID] == owner &&
          self->_tabs[tabID] == tab && !tab.closed;
      if (stillCurrent) [self->_privateQuitProbeTabs removeObjectForKey:tabID];
      completion(error == nil && disableError == nil && stillCurrent);
    }];
  }];
}

- (void)cancelPrivateQuitDialogForProbeTabID:(NSString *)tabID
                                  completion:(void (^)(BOOL))completion {
  NSDictionary *owner = _privateQuitProbeTabs[tabID];
  ArdiaCoreTab *tab = owner[@"tab"];
  ARCNativeWindowState *state = [self stateForTabID:tabID];
  NSString *invalidReason = nil;
  if (!_testing || !_probeRoot || !ARCProbeRootIsOwned(_probeRoot)) invalidReason = @"probe-root";
  else if (!_closingBrowser) invalidReason = @"not-quitting";
  else if (!_engine) invalidReason = @"engine-missing";
  else if (!owner || !tab) invalidReason = @"probe-tab-missing";
  else if (_tabs[tabID] != tab || tab.closed) invalidReason = @"tab-retired";
  else if (tab.profile.offTheRecord) invalidReason = @"tab-profile-private";
  else if (!state) invalidReason = @"window-state-missing";
  else if (![state.identity isEqualToString:owner[@"windowID"]]) invalidReason = @"owner-window-mismatch";
  else if (![state.identity isEqualToString:_primaryWindowID]) invalidReason = @"not-primary-window";
  if (invalidReason) {
    for (NSMutableDictionary *context in self->_privateProbeContexts.allValues) {
      context[@"privateQuitDialogCancelResult"] =
          [@"rejected-" stringByAppendingString:invalidReason];
    }
    completion(NO);
    return;
  }
  [tab devToolsCall:@"Page.handleJavaScriptDialog"
             params:@{@"accept": @NO}
            timeout:1
         completion:^(NSDictionary *result, NSString *error) {
    BOOL current = self->_privateQuitProbeTabs[tabID][@"tab"] == tab &&
        self->_tabs[tabID] == tab && !tab.closed;
    NSString *lowerError = error.lowercaseString ?: @"";
    for (NSMutableDictionary *context in self->_privateProbeContexts.allValues) {
      context[@"privateQuitDialogCancelResult"] = !current ? @"owner-stale" : error ?
          ([lowerError containsString:@"dialog"] && [lowerError containsString:@"no"] ?
            @"no-dialog" : @"devtools-error") : @"cancelled";
    }
    if (!current) { completion(NO); return; }
    [self endPrivateQuitCDPHoldForTabID:tabID tab:tab completion:^(BOOL ended) {
      completion(error == nil && ended);
    }];
  }];
}

- (NSDictionary *)probeExternalAppLaunchAuditForURL:(NSString *)url {
  if (!_externalAppProbeTesting || !_testing || !_engineClass || !_probeRoot ||
      !ARCProbeRootIsOwned(_probeRoot)) return nil;
  NSArray *launches = [_engineClass testExternalLaunches];
  return ARCProbeExternalAppLaunchAuditForTesting(url, launches, _probeRoot, YES);
}

- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script completion:(void (^)(NSString *))completion {
  if (!_testing) { completion(nil); return; }
  [self evaluateTab:_tabs[tabID] script:script userGesture:YES completion:completion];
}

- (NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID error:(NSError **)error {
  NSURL *resolved = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
  NSString *prefix = [_probeRoot.path stringByAppendingString:@"/"];
  if (!_testing || !prefix || ![resolved.path hasPrefix:prefix] || !_profiles[profileID]) {
    if (error) *error = ARCBridgeError(@"Component loading is restricted to disposable probe profiles.");
    return nil;
  }
  NSString *identity = [_profiles[profileID] loadComponentExtension:resolved.path];
  if (!identity) {
    if (error) *error = ARCBridgeError(@"The MV3 probe extension could not be loaded.");
    return nil;
  }
  if (!_probeExtensions[profileID]) _probeExtensions[profileID] = [NSMutableArray array];
  NSData *manifestData = [NSData dataWithContentsOfURL:[resolved URLByAppendingPathComponent:@"manifest.json"]];
  NSDictionary *manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
  [_probeExtensions[profileID] addObject:@{@"id": identity, @"name": manifest[@"name"] ?: @"Probe extension",
                                         @"version": manifest[@"version"] ?: @"unknown"}];
  return identity;
}

- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script completion:(void (^)(NSString *))completion {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  if (!_testing || !state || state.closed) { completion(nil); return; }
  [self evaluateTab:state.popup script:script completion:completion];
}

- (BOOL)ownedProbePopupID:(NSString *)popupID state:(ARCNativeWindowState **)stateOut {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  ArdiaCoreTab *popup = state.popup;
  NSString *ownerTabID = state.popupOwnerTabID;
  ArdiaCoreTab *owner = ownerTabID ? _tabs[ownerTabID] : nil;
  NSURL *url = [NSURL URLWithString:popup.url ?: @""];
  BOOL valid = _testing && state && !state.closed && !state.closing && !_closingBrowser &&
    popup && !popup.closed && [state.popupID isEqualToString:popupID] &&
    [state.popupExtensionID isEqualToString:@"nngceckbapebfimnlniiiahkandclblb"] &&
    [url.scheme isEqualToString:@"chrome-extension"] && [url.host isEqualToString:state.popupExtensionID] &&
    !url.user && !url.password && !url.port && ownerTabID.length > 0 && owner && !owner.closed &&
    [self stateForTabID:ownerTabID] == state && [self isSelectedTabID:ownerTabID] &&
    popup.profile == owner.profile && popup.profile == state.native.activeProfile;
  if (valid && stateOut) *stateOut = state;
  return valid;
}

- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion {
  [self captureProbeTab:_tabs[tabID] completion:completion];
}

- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title completion:(void (^)(BOOL))completion {
  ARCNativeWindowState *state = nil;
  if (![self ownedProbePopupID:popupID state:&state] || ![title isKindOfClass:NSString.class] ||
      title.length == 0 || title.length > 256) {
    completion(NO); return;
  }
  NSData *encoded = [NSJSONSerialization dataWithJSONObject:title options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = encoded ? [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(NO); return; }
  NSString *expression = ProbeButtonExpression(literal);
  ArdiaCoreTab *popup = state.popup;
  ClickProbeTarget(popup, expression, ^BOOL {
    return [self ownedProbePopupID:popupID state:nil] && state.popup == popup;
  }, completion);
}

- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = _tabs[tabID];
  if (!_testing || !tab || tab.closed || ![self isSelectedTabID:tabID] || elementID.length > 128) {
    completion(NO);
    return;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:elementID options:NSJSONWritingFragmentsAllowed error:nil];
  NSString *literal = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
  if (!literal) { completion(NO); return; }
  NSString *expression = [NSString stringWithFormat:
    @"(()=>{const e=document.getElementById(%@);if(!e)return null;e.scrollIntoView({block:'center'});"
     "const r=e.getBoundingClientRect();return r.width>0&&r.height>0?{x:r.x+r.width/2,y:r.y+r.height/2}:null;})()", literal];
  ClickProbeTarget(tab, expression, ^BOOL {
    return !tab.closed && self->_tabs[tabID] == tab && [self isSelectedTabID:tabID];
  }, completion);
}

- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData *))completion {
  ARCNativeWindowState *state = [self stateForPopupID:popupID];
  if (!state || state.closed) { completion(nil); return; }
  [self captureProbeTab:state.popup completion:completion];
}

- (BOOL)crashProbeTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = _tabs[tabID];
  NSURL *url = tab ? [NSURL URLWithString:tab.url] : nil;
  if (!_testing || !tab || tab.closed || ![@[@"127.0.0.1", @"localhost"] containsObject:url.host] ||
      ![url.scheme isEqualToString:@"http"] || ![url.path hasPrefix:@"/renderer-crash-"]) return NO;
  // The target may disappear before CDP can acknowledge Page.crash; the renderer callback is the evidence.
  [tab devToolsCall:@"Page.crash" params:@{} timeout:5 completion:^(NSDictionary *result, NSString *error) {}];
  return YES;
}

- (NSString *)probeKeepAliveState {
  if (!_testing || !_probeRoot || !_engine) return nil;
  return _engine.keepAliveState;
}

- (BOOL)probeQuitStoppedEventLoop {
  return _testing && _probeRoot && _shutdownGuard.stoppedEventLoop;
}

- (void)captureProbeTab:(ArdiaCoreTab *)tab completion:(void (^)(NSData *))completion {
  [self captureProbeTab:tab diagnosticCompletion:^(NSData *data, NSString *error) {
    completion(data);
  }];
}

- (void)captureProbeTab:(ArdiaCoreTab *)tab diagnosticCompletion:(void (^)(NSData *, NSString *))completion {
  if (!_testing || !tab || tab.closed) { completion(nil, @"probe-tab-unavailable"); return; }
  [tab devToolsCall:@"Page.captureScreenshot"
             params:@{@"format": @"png", @"captureBeyondViewport": @YES}
            timeout:5
         completion:^(NSDictionary *result, NSString *error) {
    NSString *base64 = result[@"data"];
    NSData *data = [base64 isKindOfClass:NSString.class]
        ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
    completion(data, error ?: (data ? nil : @"screenshot-data-missing-or-invalid-base64"));
  }];
}

@end
