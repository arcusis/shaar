// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarPrivateSupport.h"

#include <CoreFoundation/CoreFoundation.h>
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

BOOL PrivatePoliciesReady(NSDictionary *status) {
  if (![status isKindOfClass:NSDictionary.class] || status[@"error"]) return NO;
  if (![status[@"trackerDomainCount"] isKindOfClass:NSNumber.class] ||
      ![status[@"trackerRulesRevision"] isKindOfClass:NSString.class]) return NO;
  return [status[@"offTheRecord"] isEqual:@YES] &&
    [status[@"globalCookies"] isEqual:@"block"] &&
    [status[@"httpsOnly"] isEqual:@YES] &&
    [status[@"referrersEnabled"] isEqual:@NO] &&
    [status[@"webRTCIPHandlingPolicy"] isEqual:@"disable_non_proxied_udp"] &&
    [status[@"webRTCPolicyExceptionCount"] isEqual:@0] &&
    [status[@"localIPExceptionCount"] isEqual:@0] &&
    [status[@"extensionsDisabled"] isEqual:@YES] &&
    [status[@"trackerProtectionEnabled"] isEqual:@YES] &&
    [status[@"trackerDomainCount"] intValue] > 0 &&
    [status[@"trackerRulesRevision"] length] > 0;
}

BOOL PrivateIsJSONBoolean(id value) {
  return [value isKindOfClass:NSNumber.class] &&
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

const shaar_operation kShaarOpPrivateTabDiscard = (shaar_operation)208;
const shaar_operation kShaarOpPrivateTabWake = (shaar_operation)210;
const shaar_operation kShaarOpPrivateTabLifecycleGet = (shaar_operation)211;

void PrivateLifecycleFinish(void (^completion)(BOOL), BOOL accepted) {
  if (!completion) return;
  if (NSThread.isMainThread) completion(accepted);
  else dispatch_async(dispatch_get_main_queue(), ^{ completion(accepted); });
}
}  // namespace

@implementation ARCShaarRuntime (PrivateBrowsing)

- (BOOL)privateURLIsAllowed:(NSString *)url {
  if (!url.length ||
      [url rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
    return NO;
  NSURLComponents *components = [NSURLComponents componentsWithString:url];
  BOOL validPort = !components.port ||
    (components.port.integerValue > 0 && components.port.integerValue <= 65535);
  BOOL webURL = components.URL && validPort &&
    [@[@"http", @"https"] containsObject:components.scheme.lowercaseString] &&
    components.host.length && !components.user.length && !components.password.length;
  return webURL || [url isEqualToString:@"about:blank"];
}

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
      [self privateIdentityOccupied:contextID] || !open ||
      !self.privatePrivacyAvailable) {
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
  if (!ARCPrivateShaarInstallTrackerRules(session)) {
    auto close = PrivateSymbol<decltype(&shaar_private_session_close)>(
        "shaar_private_session_close");
    if (close) close(session, &error);
    completion(NO, ARCBridgeError(@"Private site protections could not be applied."));
    return;
  }
  NSMutableDictionary *state = ARCPrivateShaarState(self);
  state[@"contexts"][contextID] = [@{@"sourceProfileID": sourceProfileID,
    @"session": [NSValue valueWithPointer:session],
    @"windows": [NSMutableSet set]} mutableCopy];
  __block NSDictionary *readback = nil;
  [self privatePrivacyStatusForContextID:contextID completion:^(NSDictionary *value) {
    readback = value;
  }];
  if (!PrivatePoliciesReady(readback)) {
    [state[@"contexts"] removeObjectForKey:contextID];
    auto close = PrivateSymbol<decltype(&shaar_private_session_close)>(
        "shaar_private_session_close");
    if (close) {
      error = ARCPrivateShaarEmptyError();
      close(session, &error);
    }
    completion(NO, ARCBridgeError(@"Private privacy defaults could not be verified."));
    return;
  }
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
    @"handle": [NSValue valueWithPointer:tab], @"url": @"about:blank", @"loading": @NO,
    @"requestedURL": url} mutableCopy];
  [window[@"tabs"] addObject:tabID];
  if (self.onPrivateTabChanged)
    self.onPrivateTabChanged(contextID, windowID, tabID, @"about:blank", @"", NO, NO, NO);
  if (![url isEqualToString:@"about:blank"])
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
  if (focus([self privateEngineHandle], PrivateWindow(state[@"windows"][windowID]),
            PrivateTab(state[@"tabs"][tabID]), &error) == SHAAR_OK) return YES;
  // Hidden probe windows stay offscreen. The selected owned view is the focus target.
  NSString *selected = state[@"windows"][windowID][@"selectedTabID"];
  NSView *view = [self viewForPrivateTabID:tabID windowID:windowID contextID:contextID];
  NSWindow *window = view.window;
  return [selected isEqualToString:tabID] && view && window &&
      !window.isVisible && !window.isKeyWindow;
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

- (BOOL)performPrivatePageZoomAction:(NSString *)action tabID:(NSString *)tabID
                            windowID:(NSString *)windowID contextID:(NSString *)contextID {
  if (![@[@"get", @"in", @"out", @"reset"] containsObject:action]) return NO;
  return [self privateTabOperation:SHAAR_OP_TAB_ZOOM tabID:tabID windowID:windowID
                         contextID:contextID
                           payload:@{@"schemaVersion": @1, @"action": action}];
}

- (void)probePrivateTabLifecycleForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID
                             completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    PrivateLifecycleFinish(completion, NO);
    return;
  }
  [self submitPrivateLifecycle:kShaarOpPrivateTabLifecycleGet tabID:tabID
                    windowID:windowID contextID:contextID
                     payload:@{@"schemaVersion": @1}
                  completion:^(BOOL accepted, NSString *state) {
    BOOL capable = accepted && ([state isEqualToString:@"active"] ||
        [state isEqualToString:@"frozen"] || [state isEqualToString:@"discarded"]);
    PrivateLifecycleFinish(completion, capable);
  }];
}

- (void)submitPrivateLifecycle:(shaar_operation)operation tabID:(NSString *)tabID
                      windowID:(NSString *)windowID contextID:(NSString *)contextID
                       payload:(NSDictionary *)payload
                    completion:(void (^)(BOOL accepted, NSString *state))completion {
  if (!completion) return;
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) {
    completion(NO, nil);
    return;
  }
  NSDictionary *state = ARCPrivateShaarState(self);
  BOOL submitted = ARCPrivateShaarSubmit(
      self, PrivateScope(state[@"contexts"][contextID]),
      PrivateWindow(state[@"windows"][windowID]), PrivateTab(state[@"tabs"][tabID]),
      operation, payload, ^(NSDictionary *reply) {
        if (reply[@"error"]) {
          completion(NO, nil);
          return;
        }
        NSString *value = [reply[@"state"] isKindOfClass:NSString.class] ? reply[@"state"] : @"";
        completion(YES, value);
      });
  if (!submitted) completion(NO, nil);
}

- (void)sleepPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
               contextID:(NSString *)contextID reason:(NSString *)reason
              completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    PrivateLifecycleFinish(completion, NO);
    return;
  }
  NSString *discardReason = reason.length ? reason : @"proactive";
  [self submitPrivateLifecycle:kShaarOpPrivateTabDiscard tabID:tabID windowID:windowID
                    contextID:contextID
                      payload:@{@"schemaVersion": @1, @"reason": discardReason}
                   completion:^(BOOL accepted, NSString *state) {
    PrivateLifecycleFinish(completion, accepted && [state isEqualToString:@"discarded"]);
  }];
}

- (void)wakePrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
              contextID:(NSString *)contextID completion:(void (^)(BOOL))completion {
  if (![self tabLifecycleSupported]) {
    PrivateLifecycleFinish(completion, NO);
    return;
  }
  [self submitPrivateLifecycle:kShaarOpPrivateTabWake tabID:tabID windowID:windowID
                    contextID:contextID payload:@{@"schemaVersion": @1}
                   completion:^(BOOL accepted, NSString *state) {
    PrivateLifecycleFinish(completion, accepted && [state isEqualToString:@"active"]);
  }];
}

- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID {
  return [self reloadPrivateTabID:tabID windowID:windowID contextID:contextID
                            mode:ARCPageReloadModeNormal];
}
- (BOOL)reloadPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                 contextID:(NSString *)contextID mode:(ARCPageReloadMode)mode {
  if (mode == ARCPageReloadModeNewRenderer) return NO;
  NSString *nativeMode = @"normal";
  if (mode == ARCPageReloadModeBypassingCache) nativeMode = @"bypass_cache";
  return [self privateTabOperation:SHAAR_OP_TAB_RELOAD tabID:tabID windowID:windowID
                        contextID:contextID payload:@{@"schemaVersion": @1,
                                                      @"mode": nativeMode}];
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
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [payload[@"kind"] isEqual:@"printRequested"]) {
    if ([self privateTabOwned:tabID windowID:windowID contextID:contextID]) {
      [self receivePrivatePrintRequest:payload contextID:contextID
                             profileID:context[@"sourceProfileID"]
                              windowID:windowID tabID:tabID];
    }
    return;
  }
  if (event->kind == SHAAR_EVENT_PERMISSION &&
      [payload[@"kind"] isEqual:@"desktopCaptureRequested"]) {
    NSString *promptID = [payload[@"id"] isKindOfClass:NSString.class]
        ? payload[@"id"] : payload[@"promptID"];
    NSDictionary *window = state[@"windows"][windowID];
    NSDictionary *tab = state[@"tabs"][tabID];
    if ([promptID isKindOfClass:NSString.class] && promptID.length <= 64 &&
        [[NSUUID alloc] initWithUUIDString:promptID] &&
        [window[@"contextID"] isEqual:contextID] &&
        [tab[@"contextID"] isEqual:contextID] &&
        [tab[@"windowID"] isEqual:windowID]) {
      ARCPrivateShaarSubmit(
          self, PrivateScope(context), PrivateWindow(window), PrivateTab(tab),
          SHAAR_OP_MEDIA_CAPTURE_REPLY,
          @{@"schemaVersion": @1, @"promptID": promptID,
            @"decision": @"cancel", @"sourceToken": @""}, nil);
    }
    return;
  }
  if (event->kind == SHAAR_EVENT_TAB && [payload[@"kind"] isEqual:@"lifecycle"]) {
    if ([self privateTabOwned:tabID windowID:windowID contextID:contextID] &&
        self.onPrivateTabLifecycle) {
      NSString *state = [payload[@"state"] isKindOfClass:NSString.class] ? payload[@"state"] : @"";
      self.onPrivateTabLifecycle(contextID, windowID, tabID, state,
                                 [payload[@"audible"] boolValue], [payload[@"capturing"] boolValue]);
    }
    return;
  }
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
  if (event->kind == SHAAR_EVENT_MEDIA) {
    if ([self privateTabOwned:tabID windowID:windowID contextID:contextID] &&
        [payload[@"schemaVersion"] isEqual:@1] &&
        [payload[@"kind"] isEqualToString:@"capture_changed"] &&
        self.onPrivateMediaAccess) {
      NSNumber *camera = payload[@"camera"];
      NSNumber *microphone = payload[@"microphone"];
      NSNumber *screen = payload[@"screen"];
      if (PrivateIsJSONBoolean(camera) && PrivateIsJSONBoolean(microphone) &&
          PrivateIsJSONBoolean(screen)) {
        self.onPrivateMediaAccess(contextID, windowID, tabID, @{
          @"camera": camera, @"microphone": microphone, @"screen": screen});
      }
    }
    return;
  }
  if (event->kind != SHAAR_EVENT_NAVIGATION ||
      ![self privateTabOwned:tabID windowID:windowID contextID:contextID]) return;
  NSDictionary *failure = [payload[@"failure"] isKindOfClass:NSDictionary.class]
      ? payload[@"failure"] : nil;
  if ([payload[@"phase"] isEqual:@"stopped"] &&
      [failure[@"descriptionCode"] isEqual:@"cancelled"]) return;
  NSMutableDictionary *tab = state[@"tabs"][tabID];
  NSString *url = [payload[@"url"] isKindOfClass:NSString.class] ? payload[@"url"] : tab[@"url"];
  tab[@"url"] = url ?: @"about:blank";
  tab[@"loading"] = payload[@"loading"] ?: @NO;
  tab[@"navigationPhase"] = payload[@"phase"] ?: @"unknown";
  if (payload[@"failure"]) tab[@"navigationFailure"] = payload[@"failure"];
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
