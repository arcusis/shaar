// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridgeVerification.h"
#import "../ChromiumBridge/ChromiumProbeRoot.h"
#import "../ChromiumBridge/ChromiumRuntimeInternal.h"
#import "../ChromiumBridge/ChromiumShaarPrivateSupport.h"

#include <cstdlib>
#include <cstring>

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
  return @{@"contextIsPrivate": @YES, @"profileAlive": @(profileAlive),
      @"windowCount": @(windowIDs.count), @"tabCount": @(tabCount),
      @"allTabsLoaded": @(tabCount > 0 && allTabsLoaded),
      @"allTabsAuthoredLoopbackURL": @(tabCount > 0 && allTabsLoopback),
      @"anyTabLoading": @(anyTabLoading),
      @"allWindowsNativeWindowsAlive": @(allWindowsAlive),
      @"allWindowsHidden": @(allWindowsHidden),
      @"allTabsInNativeProfileBrowser": @(tabCount > 0 && profileAlive),
      @"allTabsAttachedToHostView": @(allSelectedViewsAttached),
      @"allTabsDetachedFromHostView": @(allBackgroundViewsDetached),
      @"allWindowsUsePrivateActiveProfile": @(windowIDs.count > 0 && profileAlive),
      @"allWindowsDisplayOwnedWebContents": @(allSelectedViewsAttached),
      @"allWindowsSelectOwnedWebContents": @(allSelectedViewsAttached),
      @"visibleNativeViewportCount": @(selectedViewCount),
      @"pendingWindowCount": @0,
      @"pendingReleaseRejected": @(windowIDs.count > 0),
      @"documentStates": documentStates,
      @"probeEvaluationError": context[@"probeEvaluationError"] ?: @""};
}
- (BOOL)privateProbeCaptureIsReadyForTabID:(NSString *)tabID windowID:(NSString *)windowID
                              contextID:(NSString *)contextID { return NO; }
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
  NSString *windowID = [self windowIDForTabID:tabID];
  NSView *tabView = [self viewForTabID:tabID];
  if (!windowID) return ARCProbeNormalSelectionAudit(tabView, nil, nil);
  return ARCProbeNormalSelectionAudit(tabView, [self hostViewForWindowID:windowID],
                                      [self windowForID:windowID]);
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
