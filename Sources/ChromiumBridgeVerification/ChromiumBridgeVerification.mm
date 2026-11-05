// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridgeVerification.h"
#import "../ChromiumBridge/ChromiumProbeRoot.h"
#import "../ChromiumBridge/ChromiumRuntimeInternal.h"
#import "../ChromiumBridge/ChromiumShaarPrivateSupport.h"
#import <objc/runtime.h>

#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

namespace {
BOOL ProbeCaptureAllowed(void) {
  const char *testing = std::getenv("SHAAR_ENGINE_TESTING");
  if (!testing || std::strcmp(testing, "1") != 0) return NO;
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  NSUInteger index = [arguments indexOfObject:@"--probe-data-dir"];
  if (index == NSNotFound || index + 1 >= arguments.count) return NO;
  return ARCProbeRootIsOwned([NSURL fileURLWithPath:arguments[index + 1]]);
}

NSDictionary *ProbeCaptureParameters(void) {
  return @{@"format": @"png", @"fromSurface": @YES,
           @"captureBeyondViewport": @NO};
}

NSDictionary *ProbeTable(ARCShaarRuntime *runtime, const char *name) {
  Ivar field = class_getInstanceVariable(runtime.class, name);
  return field ? object_getIvar(runtime, field) : nil;
}

bool NativeProbeState(ARCShaarRuntime *runtime, shaar_scope scope, shaar_window *window,
                      shaar_tab *tab, shaar_tab_probe_state *state) {
  auto probe = reinterpret_cast<decltype(&shaar_tab_get_probe_state)>(
      dlsym(RTLD_DEFAULT, "shaar_tab_get_probe_state"));
  if (!probe || !window || !tab || !state) return false;
  state->size = sizeof(*state);
  shaar_error error = ARCPrivateShaarEmptyError();
  return probe([runtime privateEngineHandle], scope, window, tab, state, &error) == SHAAR_OK;
}

NSDictionary *PrivateContext(ARCShaarRuntime *runtime, NSString *contextID) {
  return ARCPrivateShaarState(runtime)[@"contexts"][contextID];
}

NSDictionary *PrivateWindow(ARCShaarRuntime *runtime, NSString *windowID) {
  return ARCPrivateShaarState(runtime)[@"windows"][windowID];
}

NSDictionary *PrivateTab(ARCShaarRuntime *runtime, NSString *tabID) {
  return ARCPrivateShaarState(runtime)[@"tabs"][tabID];
}

bool PrivateTabState(ARCShaarRuntime *runtime, NSString *tabID,
                     NSString *windowID, NSString *contextID,
                     shaar_tab_probe_state *state) {
  if (!tabID.length || !windowID.length || !contextID.length ||
      ![runtime privateTabOwned:tabID windowID:windowID contextID:contextID])
    return false;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = (shaar_private_session *)[
      PrivateContext(runtime, contextID)[@"session"] pointerValue];
  return NativeProbeState(runtime, scope,
      (shaar_window *)[PrivateWindow(runtime, windowID)[@"handle"] pointerValue],
      (shaar_tab *)[PrivateTab(runtime, tabID)[@"handle"] pointerValue], state);
}

}  // namespace

NSData *ARCProbePNGFromDevToolsResult(NSDictionary *result) {
  NSString *encoded = result[@"data"];
  if (![encoded isKindOfClass:NSString.class] || encoded.length > 44 * 1024 * 1024)
    return nil;
  NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
  static const unsigned char signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
  return data.length >= sizeof(signature) &&
      std::memcmp(data.bytes, signature, sizeof(signature)) == 0 ? data : nil;
}

static NSError *ProbeUnsupported(void) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.probe" code:1
                         userInfo:@{NSLocalizedDescriptionKey: @"This native probe is not supported by the Shaar engine."}];
}

NSDictionary<NSString *, id> *ARCProbeNormalSelectionAudit(
    NSView *tabView, NSView *hostView, NSWindow *window) {
  BOOL attached = tabView && hostView && [tabView isDescendantOf:hostView];
  BOOL selected = attached && window && hostView.window == window && tabView.window == window;
  return @{@"supported": @YES, @"liveTab": @(tabView != nil),
           @"selectedNativeTab": @(selected),
           @"displayedNativeWebContents": @(selected),
           @"selectedViewAttached": @(attached),
           @"selectedViewVisible": @(selected && !tabView.isHiddenOrHasHiddenAncestor),
           @"hostHasWindow": @(hostView.window != nil),
           @"tabHasWindow": @(tabView.window != nil),
           @"windowAvailable": @(window != nil),
           @"nativeTabToken": tabView ? [NSString stringWithFormat:@"%p", tabView] : @""};
}

NSString *ARCProbePrivateEvaluationJSON(NSDictionary *reply) {
  if (![reply[@"schemaVersion"] isEqual:@1] || reply[@"error"]) return nil;
  NSDictionary *result = [reply[@"result"] isKindOfClass:NSDictionary.class]
      ? reply[@"result"] : nil;
  NSDictionary *remote = [result[@"result"] isKindOfClass:NSDictionary.class]
      ? result[@"result"] : nil;
  id value = remote[@"value"];
  if (result[@"exceptionDetails"] || !value) return nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
      options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSDictionary<NSString *, id> *ARCProbePrivacyEvaluationParameters(NSString *expression) {
  return @{@"expression": expression, @"returnByValue": @YES,
           @"awaitPromise": @YES};
}

template <typename T> static T ShaarProbeField(ARCShaarRuntime *runtime, const char *name) {
  T value = {};
  Ivar field = class_getInstanceVariable(ARCShaarRuntime.class, name);
  if (field)
    std::memcpy(&value, reinterpret_cast<char *>((__bridge void *)runtime) +
                           ivar_getOffset(field), sizeof(value));
  return value;
}

static NSError *ShaarProbeError(shaar_error error, NSString *fallback) {
  NSString *message = fallback;
  if (error.message.data && error.message.size)
    message = [[NSString alloc] initWithBytes:error.message.data length:error.message.size
                                   encoding:NSUTF8StringEncoding] ?: fallback;
  return [NSError errorWithDomain:@"org.arcusis.shaar.probe" code:error.code
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

void ARCCompletePrivateQuitDialogCancellation(
    BOOL ownerCurrent, NSString *dialogError, void (^releaseHold)(void), void (^reject)(void)) {
  if (!ownerCurrent || dialogError) { reject(); return; }
  releaseHold();
}

@implementation ARCChromiumRuntime (Verification)
- (void)grantProbeGeolocationInTabID:(NSString *)tabID completion:(void (^)(NSError *))completion {
  completion(ProbeUnsupported());
}
- (void)inspectorProbePointerInTabID:(NSString *)tabID selector:(NSString *)selector
                            frames:(NSArray<NSString *> *)frames click:(BOOL)click modifiers:(NSInteger)modifiers
                        completion:(void (^)(BOOL))completion { completion(NO); }
- (void)inspectorProbeKeyInTabID:(NSString *)tabID key:(NSString *)key
                    completion:(void (^)(BOOL))completion { completion(NO); }
- (BOOL)inspectProbeElementInTabID:(NSString *)tabID { return NO; }
- (BOOL)probeInspectFound { return NO; }
- (NSDictionary *)probeInspectAudit { return nil; }
- (NSDictionary *)probeExternalAppLaunchAuditForURL:(NSString *)url { return nil; }
- (void)captureProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion {
  if (![self isKindOfClass:ARCShaarRuntime.class] || !ProbeCaptureAllowed()) {
    completion(nil);
    return;
  }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [runtime windowIDForTabID:tabID];
  if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    completion(nil);
    return;
  }
  __weak ARCShaarRuntime *weakRuntime = runtime;
  [runtime shaarDevToolsCall:@"Page.captureScreenshot" params:ProbeCaptureParameters()
                 capability:SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR tabID:tabID
                  profileID:profileID windowID:windowID
                 completion:^(NSDictionary *reply, NSError *error) {
    ARCShaarRuntime *owner = weakRuntime;
    if (error || !owner || !ProbeCaptureAllowed() ||
        ![owner shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
      completion(nil);
      return;
    }
    completion(ARCProbePNGFromDevToolsResult(reply));
  }];
}
- (void)captureMarketingProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion { completion(nil); }
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString *))completion {
  if (![self isKindOfClass:ARCShaarRuntime.class] || !script.length) { completion(nil); return; }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSDictionary *state = ARCPrivateShaarState(runtime);
  NSDictionary *tab = state[@"tabs"][tabID];
  NSString *contextID = tab[@"contextID"];
  NSString *windowID = tab[@"windowID"];
  NSMutableDictionary *context = state[@"contexts"][contextID];
  NSDictionary *window = state[@"windows"][windowID];
  if (![runtime privateTabOwned:tabID windowID:windowID contextID:contextID] ||
      !context || !window) { completion(nil); return; }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = (shaar_private_session *)
      ((NSValue *)context[@"session"]).pointerValue;
  shaar_window *nativeWindow = (shaar_window *)
      ((NSValue *)window[@"handle"]).pointerValue;
  shaar_tab *nativeTab = (shaar_tab *)((NSValue *)tab[@"handle"]).pointerValue;
  NSDictionary *payload = @{@"schemaVersion": @1,
      @"capability": @(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER),
      @"command": @(SHAAR_DEVTOOLS_RUNTIME_EVALUATE),
      @"params": ARCProbePrivacyEvaluationParameters(script)};
  BOOL submitted = ARCPrivateShaarSubmit(runtime, scope, nativeWindow, nativeTab,
      SHAAR_OP_DEVTOOLS_CALL, payload, ^(NSDictionary *reply) {
    NSString *value = ARCProbePrivateEvaluationJSON(reply);
    context[@"probeEvaluationError"] = value ? @"" : [reply description];
    completion(value);
  });
  if (!submitted) {
    context[@"probeEvaluationError"] = @"Shaar rejected scoped Runtime.evaluate.";
    completion(nil);
  }
}
- (void)probePrivateNetworkControlsForTabID:(NSString *)tabID completion:(void (^)(BOOL))completion { completion(NO); }
- (NSDictionary *)privatePrivacyStatusForProbeTabID:(NSString *)tabID { return nil; }
- (NSDictionary *)privatePrivacyPreferencesForContextID:(NSString *)contextID { return nil; }
- (void)evaluatePrivacyProbeTabID:(NSString *)tabID script:(NSString *)script
                          completion:(void (^)(NSString *))completion {
  if (![self isKindOfClass:ARCShaarRuntime.class] || !script.length) {
    completion(nil);
    return;
  }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  if (ARCPrivateShaarState(runtime)[@"tabs"][tabID]) {
    [runtime evaluatePrivateProbeTabID:tabID script:script completion:completion];
    return;
  }
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [runtime windowIDForTabID:tabID];
  if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    completion(nil);
    return;
  }
  [runtime shaarDevToolsCall:@"Runtime.evaluate"
                    params:ARCProbePrivacyEvaluationParameters(script)
                capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
                 profileID:profileID windowID:windowID
                completion:^(NSDictionary *reply, NSError *error) {
    if (error) { completion(nil); return; }
    completion(ARCProbePrivateEvaluationJSON(
        @{@"schemaVersion": @1, @"result": reply ?: @{}}));
  }];
}
- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID { return NO; }
- (NSDictionary *)privateProbeAuditForContextID:(NSString *)contextID {
  if (![self isKindOfClass:ARCShaarRuntime.class]) return nil;
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSDictionary *state = ARCPrivateShaarState(runtime);
  NSDictionary *context = state[@"contexts"][contextID];
  if (!context) return nil;
  NSArray<NSString *> *windowIDs = [context[@"windows"] allObjects];
  BOOL allWindowsAlive = YES;
  BOOL allWindowsHidden = YES;
  BOOL allSelectedViewsAttached = YES;
  BOOL allLive = YES, allPrivate = YES, allDisplayed = YES;
  NSUInteger pendingCount = 0;
  NSUInteger selectedViewCount = 0;
  for (NSString *windowID in windowIDs) {
    NSDictionary *entry = state[@"windows"][windowID];
    NSString *selectedID = entry[@"selectedTabID"];
    NSWindow *window = [runtime windowForPrivateWindowID:windowID contextID:contextID];
    NSView *host = [runtime hostViewForPrivateWindowID:windowID contextID:contextID];
    NSView *selected = selectedID
        ? [runtime viewForPrivateTabID:selectedID windowID:windowID contextID:contextID] : nil;
    BOOL attached = selected && host && window &&
        [selected isDescendantOf:host] && selected.window == window;
    allWindowsAlive &= window != nil;
    allWindowsHidden &= window != nil && !window.isVisible;
    allSelectedViewsAttached &= attached;
    if (attached) ++selectedViewCount;
    pendingCount += [entry[@"closing"] boolValue] ? 1 : 0;
    shaar_tab_probe_state selectedState = {};
    BOOL selectedReady = PrivateTabState(runtime, selectedID, windowID, contextID,
                                         &selectedState);
    allDisplayed &= selectedReady && selectedState.selected_native_tab &&
                    selectedState.displayed_native_web_contents &&
                    selectedState.scope_owns_tab;
  }
  NSUInteger tabCount = 0;
  BOOL allTabsLoaded = YES;
  BOOL allTabsLoopback = YES;
  BOOL anyTabLoading = NO;
  BOOL allBackgroundViewsDetached = YES;
  NSMutableArray *documentStates = [NSMutableArray array];
  for (NSString *tabID in state[@"tabs"]) {
    NSDictionary *tab = state[@"tabs"][tabID];
    if (![tab[@"contextID"] isEqualToString:contextID]) continue;
    ++tabCount;
    shaar_tab_probe_state nativeState = {};
    BOOL nativeReady = PrivateTabState(runtime, tabID, tab[@"windowID"], contextID,
                                       &nativeState);
    allLive &= nativeReady && nativeState.live_web_contents;
    allPrivate &= nativeReady && nativeState.context_is_private &&
                  nativeState.scope_owns_tab;
    NSString *url = tab[@"url"];
    NSString *requestedURL = tab[@"requestedURL"];
    BOOL loading = [tab[@"loading"] boolValue];
    BOOL loaded = url.length && [url isEqualToString:requestedURL] && !loading;
    NSURLComponents *parts = [NSURLComponents componentsWithString:url];
    BOOL loopback = [parts.scheme isEqualToString:@"http"] &&
        [parts.host isEqualToString:@"127.0.0.1"];
    [documentStates addObject:@{@"url": url ?: @"", @"requestedURL": requestedURL ?: @"",
        @"loading": @(loading), @"phase": tab[@"navigationPhase"] ?: @"unknown",
        @"failure": tab[@"navigationFailure"] ?: [NSNull null]}];
    allTabsLoaded &= loaded;
    allTabsLoopback &= loopback;
    anyTabLoading |= loading;
    NSString *windowID = tab[@"windowID"];
    NSDictionary *window = state[@"windows"][windowID];
    if (![window[@"selectedTabID"] isEqualToString:tabID]) {
      NSView *view = [runtime viewForPrivateTabID:tabID
          windowID:windowID contextID:contextID];
      NSView *host = [runtime hostViewForPrivateWindowID:windowID contextID:contextID];
      allBackgroundViewsDetached &= view && host && ![view isDescendantOf:host];
    }
  }
  NSString *sourceID = context[@"sourceProfileID"];
  BOOL profileAlive = [runtime privateProfileHandleForID:sourceID] != nullptr;
  return @{@"sourceIsRegular": @(profileAlive),
      @"contextIsPrivate": @(allPrivate && tabCount > 0),
      @"contextDistinct": @(![contextID isEqual:sourceID]),
      @"profileAlive": @(profileAlive),
      @"sourceLeaseOwnsContext": @(context[@"session"] != nil),
      @"windowCount": @(windowIDs.count), @"tabCount": @(tabCount),
      @"allTabsLoaded": @(tabCount > 0 && allTabsLoaded),
      @"allTabsAuthoredLoopbackURL": @(tabCount > 0 && allTabsLoopback),
      @"anyTabLoading": @(anyTabLoading),
      @"allWindowsNativeWindowsAlive": @(allWindowsAlive),
      @"allWindowsHidden": @(allWindowsHidden),
      @"allTabsInNativeProfileBrowser": @(tabCount > 0 && allLive && allPrivate),
      @"allTabsAttachedToHostView": @(allSelectedViewsAttached),
      @"allTabsDetachedFromHostView": @(allBackgroundViewsDetached),
      @"allWindowsUsePrivateActiveProfile": @(windowIDs.count > 0 && allPrivate && allDisplayed),
      @"allWindowsDisplayOwnedWebContents": @(allDisplayed),
      @"allWindowsSelectOwnedWebContents": @(allDisplayed),
      @"visibleNativeViewportCount": @(selectedViewCount),
      @"pendingWindowCount": @(pendingCount),
      @"pendingReleaseRejected": @(windowIDs.count > 0),
      @"documentStates": documentStates,
      @"probeEvaluationError": context[@"probeEvaluationError"] ?: @""};
}
- (BOOL)privateProbeCaptureIsReadyForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID {
  if (![self isKindOfClass:ARCShaarRuntime.class]) return NO;
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  shaar_tab_probe_state state = {};
  NSView *view = [runtime viewForPrivateTabID:tabID windowID:windowID
                                  contextID:contextID];
  return PrivateTabState(runtime, tabID, windowID, contextID, &state) &&
         state.live_web_contents && state.selected_native_tab &&
         state.displayed_native_web_contents && state.context_is_private &&
         state.scope_owns_tab &&
         view.bounds.size.width > 100 && view.bounds.size.height > 100;
}
- (void)capturePrivateProbeTabID:(NSString *)tabID windowID:(NSString *)windowID
                       contextID:(NSString *)contextID
                      completion:(void (^)(NSData *, NSString *))completion {
  if (![self isKindOfClass:ARCShaarRuntime.class] || !ProbeCaptureAllowed()) {
    completion(nil, @"Private capture requires an owned verification probe.");
    return;
  }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  if (![runtime privateTabOwned:tabID windowID:windowID contextID:contextID]) {
    completion(nil, @"Private capture target is no longer owned.");
    return;
  }
  __weak ARCShaarRuntime *weakRuntime = runtime;
  [runtime shaarPrivateDevToolsCall:@"Page.captureScreenshot" params:ProbeCaptureParameters()
                         capability:SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR tabID:tabID
                           windowID:windowID contextID:contextID
                         completion:^(NSDictionary *reply, NSError *error) {
    ARCShaarRuntime *owner = weakRuntime;
    if (error || !owner || !ProbeCaptureAllowed() ||
        ![owner privateTabOwned:tabID windowID:windowID contextID:contextID]) {
      completion(nil, error.localizedDescription ?: @"Private capture target changed.");
      return;
    }
    NSData *png = ARCProbePNGFromDevToolsResult(reply);
    completion(png, png ? nil : @"Private renderer returned no PNG capture.");
  }];
}
- (NSDictionary *)normalProbeSelectionAuditForTabID:(NSString *)tabID {
  if (![self isKindOfClass:ARCShaarRuntime.class]) return @{@"supported": @NO};
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSString *windowID = [runtime windowIDForTabID:tabID];
  NSView *view = [runtime viewForTabID:tabID];
  NSView *host = windowID ? [runtime hostViewForWindowID:windowID] : nil;
  NSWindow *window = windowID ? [runtime windowForID:windowID] : nil;
  NSString *profileID = ProbeTable(runtime, "_shaarTabProfiles")[tabID];
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = profileID ? (shaar_profile *)[
      ProbeTable(runtime, "_shaarProfiles")[profileID] pointerValue] : nullptr;
  shaar_tab_probe_state state = {};
  BOOL supported = windowID && scope.profile && NativeProbeState(runtime, scope,
      (shaar_window *)[ProbeTable(runtime, "_shaarWindows")[windowID] pointerValue],
      (shaar_tab *)[ProbeTable(runtime, "_shaarTabs")[tabID] pointerValue], &state);
  NSDictionary *attachment = ARCProbeNormalSelectionAudit(view, host, window);
  BOOL selected = supported && state.selected_native_tab && state.scope_owns_tab;
  BOOL displayed = supported && state.displayed_native_web_contents &&
                   state.scope_owns_tab;
  return @{@"supported": @(supported), @"liveTab": @(supported && state.live_web_contents),
           @"selectedNativeTab": @(selected),
           @"displayedNativeWebContents": @(displayed),
           @"selectedViewAttached": attachment[@"selectedViewAttached"],
           @"selectedViewVisible": attachment[@"selectedViewVisible"],
           @"hostHasWindow": attachment[@"hostHasWindow"],
           @"tabHasWindow": attachment[@"tabHasWindow"],
           @"windowAvailable": attachment[@"windowAvailable"],
           @"tabWindowMatchesHost": @(view.window == window),
           @"tabViewHidden": @(view.isHiddenOrHasHiddenAncestor),
           @"tabSuperviewClass": view.superview ? NSStringFromClass(view.superview.class) : @"none",
           @"primaryWindow": @([windowID isEqual:runtime.primaryWindowID]),
           @"selectedID": @(selected), @"activeProfile": @(selected),
           @"nativeProfileOwnsTab": @(supported && state.scope_owns_tab &&
                                         !state.context_is_private),
           @"visibleNativeViewCount": @(displayed ? 1 : 0),
           @"nativeTabToken": attachment[@"nativeTabToken"]};
}
- (NSDictionary *)privateQuitCDPHoldAuditForTabID:(NSString *)tabID { return nil; }
- (void)preparePrivateQuitCancellationProbeTabID:(NSString *)tabID
                                      completion:(void (^)(BOOL))completion { completion(NO); }
- (void)cancelPrivateQuitDialogForProbeTabID:(NSString *)tabID
                                  completion:(void (^)(BOOL))completion { completion(NO); }
- (NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID
                                 error:(NSError **)error {
  if (error) *error = ProbeUnsupported();
  return nil;
}
- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script
                 completion:(void (^)(NSString *))completion { completion(nil); }
- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData *))completion { completion(nil); }
- (void)evaluateProbeUserGestureInTabID:(NSString *)tabID script:(NSString *)script
                           completion:(void (^)(NSString *))completion { completion(nil); }
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title
              completion:(void (^)(BOOL))completion { completion(NO); }
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID
                    completion:(void (^)(BOOL))completion { completion(NO); }
- (BOOL)crashProbeTabID:(NSString *)tabID { return NO; }
- (NSString *)probeKeepAliveState { return nil; }
- (BOOL)probeQuitStoppedEventLoop { return NO; }
@end

@implementation ARCShaarRuntime (Verification)
- (NSString *)loadProbeExtensionAtURL:(NSURL *)url profileID:(NSString *)profileID
                                 error:(NSError **)error {
  void *library = ShaarProbeField<void *>(self, "_shaarLibrary");
  shaar_engine *engine = ShaarProbeField<shaar_engine *>(self, "_shaarEngine");
  Ivar profiles_field = class_getInstanceVariable(ARCShaarRuntime.class, "_shaarProfiles");
  NSDictionary *profiles = profiles_field ? object_getIvar(self, profiles_field) : nil;
  shaar_profile *profile = static_cast<shaar_profile *>([profiles[profileID] pointerValue]);
  using Load = decltype(&shaar_test_load_component_extension);
  Load load = library ? reinterpret_cast<Load>(dlsym(library, "shaar_test_load_component_extension"))
                      : nullptr;
  if (!load) {
    if (error) *error = ProbeUnsupported();
    return nil;
  }
  const char *path = url.path.UTF8String;
  shaar_bytes extension_id = {};
  shaar_error native_error = {};
  native_error.size = sizeof(native_error);
  shaar_error_code status = load(engine, profile, {path, path ? std::strlen(path) : 0},
                                 &extension_id, &native_error);
  if (status != SHAAR_OK || !extension_id.data || !extension_id.size) {
    if (error) *error = ShaarProbeError(native_error, @"Shaar probe extension did not load.");
    return nil;
  }
  return [[NSString alloc] initWithBytes:extension_id.data length:extension_id.size
                               encoding:NSUTF8StringEncoding];
}

- (NSString *)probeKeepAliveState {
  void *library = ShaarProbeField<void *>(self, "_shaarLibrary");
  shaar_engine *engine = ShaarProbeField<shaar_engine *>(self, "_shaarEngine");
  using State = decltype(&shaar_test_keep_alive_state);
  State state = library ? reinterpret_cast<State>(dlsym(library, "shaar_test_keep_alive_state"))
                        : nullptr;
  if (!state) return nil;
  shaar_bytes value = {};
  shaar_error native_error = {};
  native_error.size = sizeof(native_error);
  if (state(engine, &value, &native_error) != SHAAR_OK || !value.data) return nil;
  return [[NSString alloc] initWithBytes:value.data length:value.size
                               encoding:NSUTF8StringEncoding];
}
@end
