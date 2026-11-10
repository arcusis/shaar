// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "include/ChromiumBridgeVerification.h"
#import "../ChromiumBridge/ChromiumProbeRoot.h"
#import "../ChromiumBridge/ChromiumRuntimeInternal.h"
#import "../ChromiumBridge/ChromiumMediaSession.h"
#import "../ChromiumBridge/ChromiumShaarPrivateSupport.h"
#import <objc/runtime.h>

#include <cstdlib>
#include <cmath>
#include <cstring>
#include <dlfcn.h>

#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

@interface ARCShaarRuntime (MediaEventProbe)
- (void)receiveEvent:(const shaar_event *)event;
@end

namespace {
// The testing-only operation is supplied by patch 0027 in the built engine.
constexpr NSInteger kProbeNodeLiveOperation = 1094;

BOOL ProbeCaptureAllowed(void) {
  const char *testing = std::getenv("SHAAR_ENGINE_TESTING");
  if (!testing || std::strcmp(testing, "1") != 0) return NO;
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  NSUInteger index = [arguments indexOfObject:@"--probe-data-dir"];
  if (index == NSNotFound || index + 1 >= arguments.count) return NO;
  return ARCProbeRootIsOwned([NSURL fileURLWithPath:arguments[index + 1]]);
}

void HideOwnedProbePictureInPictureWindow(NSWindow *window) {
  if (!window || !ProbeCaptureAllowed()) return;
  window.alphaValue = 0;
  window.ignoresMouseEvents = YES;
}

__attribute__((constructor)) void InstallProbePictureInPictureWindowObserver() {
  ARCSetPictureInPictureWindowObserver(HideOwnedProbePictureInPictureWindow);
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

NSDictionary *ProbeViewHierarchy(NSView *view, NSWindow *expectedWindow) {
  NSMutableArray *ancestors = [NSMutableArray array];
  for (NSView *ancestor = view; ancestor; ancestor = ancestor.superview) {
    [ancestors addObject:@{
        @"class": NSStringFromClass(ancestor.class),
        @"address": [NSString stringWithFormat:@"%p", ancestor],
        @"hidden": @(ancestor.isHidden),
        @"hiddenOrHasHiddenAncestor": @(ancestor.isHiddenOrHasHiddenAncestor),
        @"frame": NSStringFromRect(ancestor.frame),
        @"bounds": NSStringFromRect(ancestor.bounds),
        @"windowNumber": @(ancestor.window ? ancestor.window.windowNumber : -1)}];
  }
  return @{@"exists": @(view != nil),
      @"hasWindow": @(view.window != nil),
      @"inExpectedWindow": @(expectedWindow && view.window == expectedWindow),
      @"expectedWindowNumber": @(expectedWindow ? expectedWindow.windowNumber : -1),
      @"windowVisible": @(view.window.isVisible),
      @"hidden": @(view.isHidden),
      @"hiddenOrHasHiddenAncestor": @(view.isHiddenOrHasHiddenAncestor),
      @"ancestors": ancestors};
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

NSDictionary *ARCProbeShaarMediaPublicState(NSDictionary *native) {
  return ARCShaarMediaPublicState(native);
}

NSDictionary *ARCProbeShaarMediaEventDispatch(NSDictionary *payload, BOOL validOwner) {
  ARCShaarRuntime *runtime = [ARCShaarRuntime new];
  NSMutableArray *media = [NSMutableArray array];
  NSMutableArray *pip = [NSMutableArray array];
  runtime.onMediaSessionChanged = ^(NSString *tabID, NSDictionary *state) {
    [media addObject:state ?: NSNull.null];
  };
  runtime.onPictureInPictureChanged = ^(NSString *tabID, BOOL active) {
    [pip addObject:@(active)];
  };
  NSString *tabID = @"OWNED-TAB";
  NSString *profileID = @"OWNED-PROFILE";
  NSString *windowID = @"OWNED-WINDOW";
  object_setIvar(runtime, class_getInstanceVariable(runtime.class, "_shaarTabs"),
                 [@{tabID: [NSValue valueWithPointer:(void *)1]} mutableCopy]);
  object_setIvar(runtime, class_getInstanceVariable(runtime.class, "_shaarTabProfiles"),
                 [@{tabID: profileID} mutableCopy]);
  object_setIvar(runtime, class_getInstanceVariable(runtime.class, "_shaarTabWindows"),
                 [@{tabID: windowID} mutableCopy]);
  NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSString *eventWindow = validOwner ? windowID : @"FOREIGN-WINDOW";
  shaar_event event = {};
  event.size = sizeof(event);
  event.kind = SHAAR_EVENT_MEDIA;
  event.profile_id = {profileID.UTF8String, profileID.length};
  event.window_id = {eventWindow.UTF8String, eventWindow.length};
  event.tab_id = {tabID.UTF8String, tabID.length};
  event.payload_json = {(const char *)data.bytes, data.length};
  [runtime receiveEvent:&event];
  return @{@"mediaCount": @(media.count), @"pipCount": @(pip.count)};
}

NSDictionary *ARCProbeShaarDevToolsURLDispatch(NSDictionary *payload, BOOL validOwner) {
  ARCShaarRuntime *runtime = [ARCShaarRuntime new];
  __block NSDictionary *received = nil;
  runtime.onDevToolsOpenURLRequest = ^(NSDictionary *request) { received = request; };
  NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  NSString *windowID = validOwner ? payload[@"sourceWindowID"] : @"FOREIGN-WINDOW";
  NSString *tabID = payload[@"sourceTabID"];
  NSString *profileID = payload[@"profileID"];
  shaar_event event = {};
  event.size = sizeof(event);
  event.kind = SHAAR_EVENT_DEVTOOLS;
  event.window_id = {windowID.UTF8String, windowID.length};
  event.tab_id = {tabID.UTF8String, tabID.length};
  event.profile_id = {profileID.UTF8String, profileID.length};
  event.payload_json = {(const char *)data.bytes, data.length};
  [runtime receiveEvent:&event];
  return received ?: @{};
}

NSDictionary *ARCProbeDevToolsDockAudit(ARCChromiumRuntime *baseRuntime,
    NSString *tabID, NSString *windowID, NSString *contextID) {
  if (!ProbeCaptureAllowed() || ![baseRuntime isKindOfClass:ARCShaarRuntime.class]) return nil;
  auto frontend = reinterpret_cast<decltype(&shaar_devtools_frontend_view)>(
      dlsym(RTLD_DEFAULT, "shaar_devtools_frontend_view"));
  if (!frontend) return nil;
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)baseRuntime;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  shaar_window *windowHandle = nullptr;
  shaar_tab *tabHandle = nullptr;
  NSView *page = nil;
  NSView *host = nil;
  if (contextID.length) {
    if (![runtime privateTabOwned:tabID windowID:windowID contextID:contextID]) return nil;
    scope.private_session = (shaar_private_session *)[PrivateContext(runtime, contextID)[@"session"] pointerValue];
    windowHandle = (shaar_window *)[PrivateWindow(runtime, windowID)[@"handle"] pointerValue];
    tabHandle = (shaar_tab *)[PrivateTab(runtime, tabID)[@"handle"] pointerValue];
    page = [runtime viewForPrivateTabID:tabID windowID:windowID contextID:contextID];
    host = [runtime hostViewForPrivateWindowID:windowID contextID:contextID];
  } else {
    NSString *profileID = ProbeTable(runtime, "_shaarTabProfiles")[tabID];
    if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) return nil;
    scope.profile = (shaar_profile *)[ProbeTable(runtime, "_shaarProfiles")[profileID] pointerValue];
    windowHandle = (shaar_window *)[ProbeTable(runtime, "_shaarWindows")[windowID] pointerValue];
    tabHandle = (shaar_tab *)[ProbeTable(runtime, "_shaarTabs")[tabID] pointerValue];
    page = [runtime viewForTabID:tabID];
    host = [runtime hostViewForWindowID:windowID];
  }
  NSView *dock = (__bridge NSView *)frontend([runtime privateEngineHandle], scope, windowHandle, tabHandle);
  auto geometry = reinterpret_cast<decltype(&shaar_test_devtools_geometry)>(
      dlsym(RTLD_DEFAULT, "shaar_test_devtools_geometry"));
  shaar_devtools_geometry measured = {};
  measured.size = sizeof(measured);
  shaar_error geometryError = ARCPrivateShaarEmptyError();
  BOOL geometryReady = dock && geometry &&
      geometry([runtime privateEngineHandle], scope, windowHandle, tabHandle,
               &measured, &geometryError) == SHAAR_OK;
  double gap = geometryReady ? std::abs(measured.frontend_placeholder_right -
                                       measured.inspected_page_right) : -1;
  NSView *container = page.superview;
  NSPoint dockPoint = NSZeroPoint;
  BOOL hasDockPoint = NO;
  if (dock && container && dock.superview == container) {
    NSRect bounds = container.bounds;
    if (NSMaxX(page.frame) < NSMaxX(bounds) - 24) {
      dockPoint = NSMakePoint(NSMaxX(bounds) - 24, NSMaxY(bounds) - 18);
      hasDockPoint = YES;
    } else if (NSMinY(page.frame) > NSMinY(bounds) + 18) {
      dockPoint = NSMakePoint(NSMaxX(bounds) - 24, NSMinY(page.frame) - 18);
      hasDockPoint = YES;
    }
  }
  NSView *hit = hasDockPoint
      ? [container hitTest:[container convertPoint:dockPoint toView:container.superview]] : nil;
  BOOL frontendHit = hit && (hit == dock || [hit isDescendantOf:dock]);
  BOOL hidden = YES;
  for (NSWindow *window in NSApp.windows) hidden &= !window.isVisible;
  return @{@"open": @(dock != nil), @"sameWindow": @(page.window && dock.window == page.window),
      @"sameContainer": @(page.superview && dock.superview == page.superview),
      @"containerWidth": @(page.superview.bounds.size.width),
      @"pageAboveFrontend": @(dock && page.superview &&
          [page.superview.subviews indexOfObject:page] >
          [page.superview.subviews indexOfObject:dock]),
      @"geometryReady": @(geometryReady), @"gap": @(gap),
      @"frontendPlaceholderRight": @(measured.frontend_placeholder_right),
      @"inspectedPageRight": @(measured.inspected_page_right),
      @"frontendCoversContainer": @(dock && page.superview &&
          std::abs(NSWidth(dock.frame) - NSWidth(page.superview.bounds)) <= 1),
      @"frontendHitNearTabStrip": @(frontendHit),
      @"tabStripHitView": hit ? NSStringFromClass(hit.class) : @"none",
      @"tabStripHitPoint": hasDockPoint ? NSStringFromPoint(dockPoint) : @"none",
      @"allWindowsHidden": @(hidden), @"pageWidth": @(page.frame.size.width),
      @"pageHeight": @(page.frame.size.height), @"hostWidth": @(host.bounds.size.width),
      @"frontendWidth": @(dock.frame.size.width), @"frontendHeight": @(dock.frame.size.height),
      @"pageFrame": NSStringFromRect(page.frame), @"frontendFrame": NSStringFromRect(dock.frame)};
}

NSArray<NSDictionary *> *ARCProbeTracePrivateSelection(
    ARCChromiumRuntime *runtime, void (^action)(void)) {
  if (!ProbeCaptureAllowed() ||
      ![NSProcessInfo.processInfo.arguments containsObject:@"--probe-shaar-inspector"])
    return nil;
  NSCAssert(NSThread.isMainThread, @"Selection tracing requires the main thread");
  SEL selector = @selector(selectPrivateTabID:windowID:contextID:);
  Method method = class_getInstanceMethod(runtime.class, selector);
  if (!method) return nil;
  IMP previous = method_getImplementation(method);
  using Select = BOOL (*)(id, SEL, NSString *, NSString *, NSString *);
  Select original = reinterpret_cast<Select>(previous);
  NSMutableArray *calls = [NSMutableArray array];
  IMP trace = imp_implementationWithBlock(^BOOL(id receiver, NSString *tabID,
                                               NSString *windowID, NSString *contextID) {
    BOOL accepted = original(receiver, selector, tabID, windowID, contextID);
    if (receiver == runtime)
      [calls addObject:@{@"tabID": tabID, @"windowID": windowID,
                         @"contextID": contextID, @"accepted": @(accepted)}];
    return accepted;
  });
  method_setImplementation(method, trace);
  @try { action(); }
  @finally {
    method_setImplementation(method, previous);
    imp_removeBlock(trace);
  }
  return [calls copy];
}

BOOL ARCProbePopupIdentifier(NSString *popupID) {
  if (popupID.length != 36) return NO;
  for (NSUInteger index = 0; index < popupID.length; index++) {
    unichar character = [popupID characterAtIndex:index];
    BOOL dashSlot = index == 8 || index == 13 || index == 18 || index == 23;
    if (dashSlot) {
      if (character != '-') return NO;
      continue;
    }
    if (character < '0' || (character > '9' && character < 'a') || character > 'f') return NO;
  }
  return YES;
}

BOOL ARCProbePopupExpression(NSString *script) {
  return script.length > 0 && script.length <= 8192;
}

NSString *ARCProbeEvaluationJSON(NSDictionary *result) {
  if (![result isKindOfClass:NSDictionary.class] || result[@"exceptionDetails"]) return nil;
  NSDictionary *remote = [result[@"result"] isKindOfClass:NSDictionary.class]
      ? result[@"result"] : nil;
  id value = remote[@"value"];
  if (!value) return nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                             options:NSJSONWritingFragmentsAllowed error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

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

NSDictionary<NSString *, id> *ARCProbePrivateEvaluationPayload(
    NSString *expression, BOOL probeVisibleForRenderer) {
  NSMutableDictionary *payload = [@{@"schemaVersion": @1,
      @"capability": @(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER),
      @"command": @(SHAAR_DEVTOOLS_RUNTIME_EVALUATE),
      @"params": ARCProbePrivacyEvaluationParameters(expression)} mutableCopy];
  if (probeVisibleForRenderer) payload[@"probeVisibleForRenderer"] = @YES;
  return payload;
}

NSDictionary<NSString *, id> *ARCProbePrivatePrivacyPreferences(
    NSDictionary *status, NSInteger wildcardStatus) {
  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  for (NSString *key in @[@"credentials_enable_service", @"autofill.profile_enabled",
                          @"autofill.credit_card_enabled"]) {
    NSMutableDictionary *pair = [NSMutableDictionary dictionary];
    id normal = status[[key stringByAppendingString:@"Normal"]];
    id privateValue = status[[key stringByAppendingString:@"Private"]];
    if (normal) pair[@"normal"] = normal;
    if (privateValue) pair[@"private"] = privateValue;
    result[key] = pair;
  }
  if (wildcardStatus == SHAAR_INVALID_ARGUMENT) {
    result[@"wildcardCookieSetting"] = @{
        @"error": @"origin must be an http(s) origin",
        @"nativeStatus": @(wildcardStatus)};
  } else {
    result[@"wildcardCookieSetting"] = @{@"nativeStatus": @(wildcardStatus)};
  }
  return result;
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

@interface ARCPrivateProbeCloseCanceller : NSObject <NSWindowDelegate>
@end

@implementation ARCPrivateProbeCloseCanceller
- (BOOL)windowShouldClose:(NSWindow *)sender {
  return NO;
}
@end

@implementation ARCChromiumRuntime (Verification)
- (void)probeDevToolsRouteInTabID:(NSString *)tabID operation:(NSInteger)operation
                         payload:(NSDictionary *)payload
                      completion:(void (^)(BOOL))completion {
  if (!completion) return;
  if (![self isKindOfClass:ARCShaarRuntime.class] || !ProbeCaptureAllowed() ||
      (operation != SHAAR_OP_PROBE_DEVTOOLS_OPEN_URL &&
       operation != SHAAR_OP_PROBE_NODE_FRONTEND &&
       operation != kProbeNodeLiveOperation &&
       operation != SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED)) {
    completion(NO);
    return;
  }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [runtime windowIDForTabID:tabID];
  if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID
                            windowID:windowID]) {
    completion(NO);
    return;
  }
  if (![runtime shaarDevToolsSubmit:(shaar_operation)operation tabID:tabID
                         profileID:profileID windowID:windowID payload:payload
                        completion:^(NSDictionary *reply, NSError *error) {
                          NSString *key = operation == SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED
                            ? @"attached" : @"submitted";
                          completion(!error && [reply[key] boolValue]);
                        }]) completion(NO);
}
- (void)probeDevToolsUIOpenForTabID:(NSString *)tabID
                         completion:(void (^)(NSNumber *))completion {
  if (!completion) return;
  void (^finish)(NSNumber *) = ^(NSNumber *open) {
    if (NSThread.isMainThread) completion(open);
    else dispatch_async(dispatch_get_main_queue(), ^{ completion(open); });
  };
  if (![self isKindOfClass:ARCShaarRuntime.class] || !ProbeCaptureAllowed()) {
    finish(nil);
    return;
  }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [runtime windowIDForTabID:tabID];
  [runtime shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_UI_STATE tabID:tabID
                     profileID:profileID windowID:windowID
                       payload:@{@"schemaVersion": @1}
                    completion:^(NSDictionary *reply, NSError *error) {
                      NSNumber *open = [reply[@"open"] isKindOfClass:NSNumber.class]
                        ? reply[@"open"] : nil;
                      finish(error ? nil : open);
                    }];
}
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
  [runtime shaarDevToolsSubmit:SHAAR_OP_PROBE_CAPTURE_TAB tabID:tabID
                    profileID:profileID windowID:windowID
                      payload:@{@"schemaVersion": @1}
                   completion:^(NSDictionary *reply, NSError *error) {
    ARCShaarRuntime *owner = weakRuntime;
    if (error || !owner || !ProbeCaptureAllowed() ||
        ![owner shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
      if (error) NSLog(@"Shaar normal renderer capture failed: %@", error.localizedDescription);
      completion(nil);
      return;
    }
    NSData *png = ARCProbePNGFromDevToolsResult(reply);
    if (!png) NSLog(@"Shaar normal renderer capture returned no PNG: %@", reply);
    completion(png);
  }];
}
- (void)captureMarketingProbeTabID:(NSString *)tabID completion:(void (^)(NSData *))completion { completion(nil); }
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
        probeVisibleForRenderer:(BOOL)probeVisibleForRenderer
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
  if (probeVisibleForRenderer) {
    NSURLComponents *url = [NSURLComponents componentsWithString:tab[@"url"] ?: @""];
    NSWindow *native = [runtime windowForPrivateWindowID:windowID contextID:contextID];
    if (!ProbeCaptureAllowed() || ![window[@"selectedTabID"] isEqual:tabID] ||
        ![url.scheme isEqual:@"http"] || ![url.host isEqual:@"127.0.0.1"] ||
        !native || native.isVisible) { completion(nil); return; }
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = (shaar_private_session *)
      ((NSValue *)context[@"session"]).pointerValue;
  shaar_window *nativeWindow = (shaar_window *)
      ((NSValue *)window[@"handle"]).pointerValue;
  shaar_tab *nativeTab = (shaar_tab *)((NSValue *)tab[@"handle"]).pointerValue;
  NSDictionary *payload = ARCProbePrivateEvaluationPayload(script, probeVisibleForRenderer);
  BOOL submitted = ARCPrivateShaarSubmit(runtime, scope, nativeWindow, nativeTab,
      SHAAR_OP_DEVTOOLS_CALL, payload, ^(NSDictionary *reply) {
    NSString *value = ARCProbePrivateEvaluationJSON(reply);
    context[@"probeEvaluationError"] = value ? @"" : [reply description];
    if (!value) NSLog(@"Private privacy evaluation failed: %@", reply);
    completion(value);
  });
  if (!submitted) {
    context[@"probeEvaluationError"] = @"Shaar rejected scoped Runtime.evaluate.";
    completion(nil);
  }
}
- (void)evaluatePrivateProbeTabID:(NSString *)tabID script:(NSString *)script
                       completion:(void (^)(NSString *))completion {
  [self evaluatePrivateProbeTabID:tabID script:script probeVisibleForRenderer:NO
                      completion:completion];
}
- (void)evaluatePrivatePermissionProbeTabID:(NSString *)tabID script:(NSString *)script
                                completion:(void (^)(NSString *))completion {
  [self evaluatePrivateProbeTabID:tabID script:script probeVisibleForRenderer:YES
                      completion:completion];
}
- (void)probePrivateNetworkControlsForTabID:(NSString *)tabID completion:(void (^)(BOOL))completion { completion(NO); }
- (NSDictionary *)privatePrivacyStatusForProbeTabID:(NSString *)tabID { return nil; }
- (NSDictionary *)privatePrivacyPreferencesForContextID:(NSString *)contextID {
  if (![self isKindOfClass:ARCShaarRuntime.class] || !ProbeCaptureAllowed()) return nil;
  auto policy = reinterpret_cast<decltype(&shaar_private_session_privacy_status)>(
      dlsym(RTLD_DEFAULT, "shaar_private_session_privacy_status"));
  auto cookie = reinterpret_cast<decltype(&shaar_private_session_cookie_setting)>(
      dlsym(RTLD_DEFAULT, "shaar_private_session_cookie_setting"));
  NSDictionary *context = PrivateContext((ARCShaarRuntime *)self, contextID);
  shaar_private_session *session = (shaar_private_session *)[context[@"session"] pointerValue];
  if (!policy || !cookie || !session) return nil;
  char buffer[4096] = {};
  shaar_error error = ARCPrivateShaarEmptyError();
  if (policy(session, buffer, sizeof(buffer), &error) != SHAAR_OK) return nil;
  const char *end = static_cast<const char *>(memchr(buffer, '\0', sizeof(buffer)));
  NSData *data = end ? [NSData dataWithBytes:buffer length:end - buffer] : nil;
  NSDictionary *status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![status isKindOfClass:NSDictionary.class]) return nil;
  int allowed = 0;
  error = ARCPrivateShaarEmptyError();
  shaar_error_code wildcardStatus = cookie(session, {"*", 1}, 1, 1, &allowed, &error);
  return ARCProbePrivatePrivacyPreferences(status, wildcardStatus);
}
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
    if (error) {
      NSLog(@"Normal privacy evaluation failed: %@", error);
      completion(nil);
      return;
    }
    NSString *value = ARCProbePrivateEvaluationJSON(
        @{@"schemaVersion": @1, @"result": reply ?: @{}});
    if (!value) NSLog(@"Normal privacy evaluation returned no value: %@", reply);
    completion(value);
  }];
}
- (BOOL)attemptCancelledPrivateProbeCloseID:(NSString *)windowID {
  if (![self isKindOfClass:ARCShaarRuntime.class] || !windowID.length) return NO;
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSMutableDictionary *state = ARCPrivateShaarState(runtime);
  NSMutableDictionary *entry = state[@"windows"][windowID];
  if (![entry isKindOfClass:NSMutableDictionary.class] || [entry[@"closing"] boolValue]) return NO;
  NSString *contextID = entry[@"contextID"];
  NSWindow *window = [runtime windowForPrivateWindowID:windowID contextID:contextID];
  if (!window) return NO;
  ARCPrivateProbeCloseCanceller *canceller = [ARCPrivateProbeCloseCanceller new];
  id<NSWindowDelegate> previous = window.delegate;
  window.delegate = canceller;
  [window performClose:nil];
  if (window.delegate == canceller) window.delegate = previous;
  NSString *tabID = [entry[@"tabs"] anyObject];
  NSDictionary *tab = state[@"tabs"][tabID];
  return state[@"windows"][windowID] == entry && ![entry[@"closing"] boolValue] &&
      [tab isKindOfClass:NSDictionary.class] && ![tab[@"closing"] boolValue];
}
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
    NSView *nativeView = [runtime viewForPrivateTabID:tabID
        windowID:tab[@"windowID"] contextID:contextID];
    NSWindow *nativeWindow = [runtime windowForPrivateWindowID:tab[@"windowID"]
        contextID:contextID];
    [documentStates addObject:@{@"tabID": tabID, @"url": url ?: @"", @"requestedURL": requestedURL ?: @"",
        @"loading": @(loading), @"phase": tab[@"navigationPhase"] ?: @"unknown",
        @"nativeStateSupported": @(nativeReady),
        @"selectedNativeTab": @(nativeReady && nativeState.selected_native_tab),
        @"displayedNativeWebContents": @(nativeReady && nativeState.displayed_native_web_contents),
        @"nativeViewHierarchy": ProbeViewHierarchy(nativeView, nativeWindow),
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
  shaar_profile *sourceProfile = [runtime privateProfileHandleForID:sourceID];
  BOOL profileAlive = sourceProfile != nullptr;
  // One source profile owns the shared private session. Pending contexts have no tabs yet.
  BOOL sessionLive = context[@"session"] != nil;
  BOOL contextIsPrivate = sessionLive && (tabCount == 0 || allPrivate);
  NSString *profileToken = sourceProfile
      ? [NSString stringWithFormat:@"%p", sourceProfile] : @"";
  NSDictionary *audit = @{@"sourceIsRegular": @(profileAlive),
      @"contextIsPrivate": @(contextIsPrivate),
      @"profileToken": profileToken,
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
  NSString *cancelResult = context[@"privateQuitDialogCancelResult"];
  if (![cancelResult isKindOfClass:NSString.class]) return audit;
  NSMutableDictionary *withCancelResult = [audit mutableCopy];
  withCancelResult[@"privateQuitDialogCancelResult"] = cancelResult;
  return withCancelResult;
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
  NSDictionary *state = ARCPrivateShaarState(runtime);
  NSDictionary *context = state[@"contexts"][contextID];
  NSDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = static_cast<shaar_private_session *>(
      [context[@"session"] pointerValue]);
  auto *windowHandle = static_cast<shaar_window *>([window[@"handle"] pointerValue]);
  auto *tabHandle = static_cast<shaar_tab *>([tab[@"handle"] pointerValue]);
  BOOL submitted = ARCPrivateShaarSubmit(runtime, scope, windowHandle, tabHandle,
      SHAAR_OP_PROBE_CAPTURE_TAB, @{@"schemaVersion": @1}, ^(NSDictionary *envelope) {
    ARCShaarRuntime *owner = weakRuntime;
    if (!owner || !ProbeCaptureAllowed() ||
        ![owner privateTabOwned:tabID windowID:windowID contextID:contextID]) {
      completion(nil, @"Private capture target changed.");
      return;
    }
    NSDictionary *reply = [envelope[@"result"] isKindOfClass:NSDictionary.class]
        ? envelope[@"result"] : nil;
    NSData *png = ARCProbePNGFromDevToolsResult(reply);
    completion(png, png ? nil : @"Private renderer returned no PNG capture.");
  });
  if (!submitted) completion(nil, @"Private capture request was rejected.");
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
                           completion:(void (^)(NSString *))completion {
  static NSString *const kAuthoredGesture =
      @"(()=>{document.getElementById('video').play();return {started:true};})()";
  static NSString *const kAuthoredClipGesture =
      @"(()=>{const c=document.getElementById('clip');c.currentTime=5;"
       "c.play().then(()=>c.requestPictureInPicture());return {opened:true};})()";
  BOOL clipGesture = [script isEqualToString:kAuthoredClipGesture];
  if (![self isKindOfClass:ARCShaarRuntime.class] || !ProbeCaptureAllowed() ||
      (![script isEqualToString:kAuthoredGesture] && !clipGesture)) {
    completion(nil);
    return;
  }
  ARCShaarRuntime *runtime = (ARCShaarRuntime *)self;
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [runtime windowIDForTabID:tabID];
  if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID
                            windowID:windowID]) {
    completion(nil);
    return;
  }
  BOOL submitted = [runtime shaarDevToolsSubmit:SHAAR_OP_PROBE_MEDIA_GESTURE
      tabID:tabID profileID:profileID windowID:windowID
      payload:@{@"schemaVersion": @1, @"action": clipGesture ? @"playPiP" : @"play",
                @"elementID": clipGesture ? @"clip" : @"video"}
      completion:^(NSDictionary *reply, NSError *error) {
        if (error || ![reply[clipGesture ? @"opened" : @"started"] boolValue]) {
          completion(nil);
          return;
        }
        completion(clipGesture ? @"{\"opened\":true}" : @"{\"started\":true}");
      }];
  if (!submitted) {
    completion(nil);
  }
}
- (void)clickProbePopupID:(NSString *)popupID buttonTitle:(NSString *)title
              completion:(void (^)(BOOL))completion { completion(NO); }
- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID
                    completion:(void (^)(BOOL))completion { completion(NO); }
- (NSDictionary *)privateNavigationProbeAuditForTabID:(NSString *)tabID { return nil; }
- (BOOL)crashProbeTabID:(NSString *)tabID { return NO; }
- (NSString *)probeKeepAliveState { return nil; }
- (BOOL)probeQuitStoppedEventLoop { return NO; }
@end

static const NSInteger kProbePageDisableCommand = 62;
static const NSInteger kProbePageHandleJavaScriptDialogCommand = 63;
static const void *kPrivateQuitHoldOwnersKey = &kPrivateQuitHoldOwnersKey;

BOOL ARCProbeDevToolsCommandIsUnknown(NSString *message) {
  return [message containsString:@"unknown DevTools"];
}

BOOL ARCProbeLoopbackDocumentURL(NSString *href) {
  NSURLComponents *url = [NSURLComponents componentsWithString:href ?: @""];
  if (![url.scheme.lowercaseString isEqualToString:@"http"]) return NO;
  NSString *host = url.host.lowercaseString;
  if ([host isEqualToString:@"127.0.0.1"]) return YES;
  return [host isEqualToString:@"localhost"];
}

NSString *ARCProbePrivateQuitDialogResult(BOOL ownerCurrent, NSString *dialogError) {
  if (!ownerCurrent) return @"owner-stale";
  if (!dialogError) return @"cancelled";
  NSString *lower = dialogError.lowercaseString;
  if ([lower containsString:@"dialog"] && [lower containsString:@"no"]) return @"no-dialog";
  return @"devtools-error";
}

static NSMutableDictionary *PrivateQuitHoldOwners(ARCShaarRuntime *runtime) {
  if (!runtime) return nil;
  NSMutableDictionary *owners = objc_getAssociatedObject(runtime, kPrivateQuitHoldOwnersKey);
  if (!owners) {
    owners = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, kPrivateQuitHoldOwnersKey, owners,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return owners;
}

static BOOL ProbeQuitHoldEventIsSafe(NSString *event) {
  static NSString *const prefix = @"arcusis-private-quit-cdp-";
  if (![event hasPrefix:prefix]) return NO;
  NSString *suffix = [event substringFromIndex:prefix.length];
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"0123456789ABCDEFabcdef-"];
  return suffix.length == 36 &&
      [suffix rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *ProbeQuitHoldExpression(NSString *event) {
  return [NSString stringWithFormat:
      @"(()=>{const key='%@';const holds=window.__arcusisPrivateQuitCDPHolds||"
      "(window.__arcusisPrivateQuitCDPHolds=Object.create(null));"
      "holds[key]={started:true,timedOut:false};"
      "return new Promise(resolve=>{const timer=setTimeout(()=>{holds[key].timedOut=true;"
      "resolve(true)},30000);addEventListener(key,()=>{clearTimeout(timer);"
      "delete holds[key];resolve(true)},{once:true});});})()", event];
}

static NSString *ProbeQuitHoldStateExpression(NSString *event) {
  return [NSString stringWithFormat:
      @"(()=>{const holds=window.__arcusisPrivateQuitCDPHolds;"
      "return holds&&holds['%@']||null})()", event];
}

static NSString *ProbeQuitHoldReleaseExpression(NSString *event) {
  return [NSString stringWithFormat:@"dispatchEvent(new Event('%@'))", event];
}

static NSDictionary *ProbeDevToolsPayload(NSInteger command, NSDictionary *params) {
  return @{@"schemaVersion": @1,
           @"capability": @(SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER),
           @"command": @(command), @"params": params ?: @{}};
}

static NSString *ProbeEvaluateString(NSDictionary *result) {
  NSDictionary *remote = [result[@"result"] isKindOfClass:NSDictionary.class]
      ? result[@"result"] : nil;
  return [remote[@"value"] isKindOfClass:NSString.class] ? remote[@"value"] : nil;
}

static BOOL ProbeQuitHoldStateIsPending(NSDictionary *result) {
  NSDictionary *remote = [result[@"result"] isKindOfClass:NSDictionary.class]
      ? result[@"result"] : nil;
  NSDictionary *value = [remote[@"value"] isKindOfClass:NSDictionary.class]
      ? remote[@"value"] : nil;
  return [value[@"started"] boolValue] && ![value[@"timedOut"] boolValue];
}

static BOOL PrivateQuitProbeTabIsEligible(ARCShaarRuntime *runtime, NSString *tabID) {
  if (!ProbeCaptureAllowed() || runtime.isQuitting) return NO;
  NSString *windowID = [runtime windowIDForTabID:tabID];
  if (![windowID isEqualToString:runtime.primaryWindowID]) return NO;
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) return NO;
  id selected = ProbeTable(runtime, "_shaarSelectedTabs")[runtime.primaryWindowID];
  if (![selected isEqual:tabID]) return NO;
  return [ARCPrivateShaarState(runtime)[@"contexts"] count] > 0;
}

static BOOL PrivateQuitHoldOwnerCurrent(ARCShaarRuntime *runtime, NSString *tabID,
                                        NSDictionary *owner) {
  if (!runtime || PrivateQuitHoldOwners(runtime)[tabID] != owner) return NO;
  id tabHandle = ProbeTable(runtime, "_shaarTabs")[tabID];
  if (!tabHandle || owner[@"tab"] != tabHandle) return NO;
  NSString *windowID = [runtime windowIDForTabID:tabID];
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  return [runtime shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID];
}

static void RecordPrivateQuitDialogResult(ARCShaarRuntime *runtime, NSString *result) {
  for (id context in [ARCPrivateShaarState(runtime)[@"contexts"] objectEnumerator]) {
    if ([context isKindOfClass:NSMutableDictionary.class])
      context[@"privateQuitDialogCancelResult"] = result;
  }
}

static NSString *PrivateQuitCancelRejection(ARCShaarRuntime *runtime, NSString *tabID,
                                            NSDictionary *owner) {
  if (!ProbeCaptureAllowed()) return @"probe-root";
  if (!runtime.isQuitting) return @"not-quitting";
  if (![runtime privateEngineHandle]) return @"engine-missing";
  if (!owner) return @"probe-tab-missing";
  if (ARCPrivateShaarState(runtime)[@"tabs"][tabID]) return @"tab-profile-private";
  id tabHandle = ProbeTable(runtime, "_shaarTabs")[tabID];
  if (!tabHandle || owner[@"tab"] != tabHandle) return @"tab-retired";
  NSString *windowID = [runtime windowIDForTabID:tabID];
  if (!windowID.length) return @"window-state-missing";
  if (![windowID isEqualToString:owner[@"windowID"]]) return @"owner-window-mismatch";
  if (![windowID isEqualToString:runtime.primaryWindowID]) return @"not-primary-window";
  NSString *profileID = [runtime shaarDevToolsProfileIDForTabID:tabID];
  if (![runtime shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID])
    return @"tab-retired";
  return nil;
}

@interface ARCShaarRuntime (PrivateQuitHold)
- (void)beginPrivateQuitCDPHoldForTabID:(NSString *)tabID
                             completion:(void (^)(BOOL))completion;
- (void)endPrivateQuitCDPHoldForTabID:(NSString *)tabID
                                owner:(NSMutableDictionary *)owner
                           completion:(void (^)(BOOL))completion;
@end

@implementation ARCShaarRuntime (PrivateQuitHold)

- (void)beginPrivateQuitCDPHoldForTabID:(NSString *)tabID
                             completion:(void (^)(BOOL))completion {
  NSString *event = [@"arcusis-private-quit-cdp-" stringByAppendingString:NSUUID.UUID.UUIDString];
  if (!ProbeQuitHoldEventIsSafe(event) || !PrivateQuitProbeTabIsEligible(self, tabID) ||
      PrivateQuitHoldOwners(self)[tabID]) {
    completion(NO);
    return;
  }
  NSString *profileID = [self shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [self windowIDForTabID:tabID];
  NSMutableDictionary *owner = [@{@"tab": ProbeTable(self, "_shaarTabs")[tabID],
      @"windowID": windowID, @"event": event, @"holdCommandPending": @YES,
      @"holdConfirmedPending": @NO, @"releaseStarted": @NO} mutableCopy];
  PrivateQuitHoldOwners(self)[tabID] = owner;
  __weak ARCShaarRuntime *weakSelf = self;
  __block BOOL accepted = NO;
  accepted = [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_CALL tabID:tabID
      profileID:profileID windowID:windowID
      payload:ProbeDevToolsPayload(SHAAR_DEVTOOLS_RUNTIME_EVALUATE, @{
          @"expression": ProbeQuitHoldExpression(event), @"awaitPromise": @YES})
      completion:^(NSDictionary *, NSError *error) {
        if (!accepted) return;
        ARCShaarRuntime *runtime = weakSelf;
        NSMutableDictionary *current = PrivateQuitHoldOwners(runtime)[tabID];
        if (current == owner) current[@"holdCommandPending"] = @NO;
        if (!runtime || current != owner) return;
        if (error || !PrivateQuitHoldOwnerCurrent(runtime, tabID, owner))
          owner[@"holdConfirmedPending"] = @NO;
        [runtime endPrivateQuitCDPHoldForTabID:tabID owner:owner completion:^(BOOL ended) {}];
      }];
  if (!accepted) {
    [PrivateQuitHoldOwners(self) removeObjectForKey:tabID];
    completion(NO);
    return;
  }
  [self shaarDevToolsCall:@"Page.enable" params:@{}
              capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
               profileID:profileID windowID:windowID
              completion:^(NSDictionary *, NSError *error) {
    ARCShaarRuntime *runtime = weakSelf;
    BOOL current = runtime && PrivateQuitHoldOwnerCurrent(runtime, tabID, owner);
    if (error || !current) {
      if (runtime && PrivateQuitHoldOwners(runtime)[tabID] == owner)
        [runtime endPrivateQuitCDPHoldForTabID:tabID owner:owner completion:^(BOOL ended) {}];
      completion(NO);
      return;
    }
    [runtime shaarDevToolsCall:@"Runtime.evaluate"
        params:@{@"expression": ProbeQuitHoldStateExpression(event), @"returnByValue": @YES}
        capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
        profileID:profileID windowID:windowID
        completion:^(NSDictionary *result, NSError *verifyError) {
          ARCShaarRuntime *verified = weakSelf;
          NSMutableDictionary *verifiedOwner = PrivateQuitHoldOwners(verified)[tabID];
          BOOL pending = verified && !verifyError && verifiedOwner == owner &&
              PrivateQuitHoldOwnerCurrent(verified, tabID, owner) &&
              ProbeQuitHoldStateIsPending(result) &&
              [verifiedOwner[@"holdCommandPending"] boolValue];
          if (verifiedOwner == owner) verifiedOwner[@"holdConfirmedPending"] = @(pending);
          if (!pending && verified && verifiedOwner == owner)
            [verified endPrivateQuitCDPHoldForTabID:tabID owner:owner completion:^(BOOL ended) {}];
          completion(pending);
        }];
  }];
}

- (void)endPrivateQuitCDPHoldForTabID:(NSString *)tabID
                                owner:(NSMutableDictionary *)owner
                           completion:(void (^)(BOOL))completion {
  if (!completion) completion = ^(BOOL ended) {};
  NSString *event = owner[@"event"];
  if (!PrivateQuitHoldOwnerCurrent(self, tabID, owner) || !ProbeQuitHoldEventIsSafe(event)) {
    completion(NO);
    return;
  }
  if ([owner[@"releaseStarted"] boolValue]) {
    completion(NO);
    return;
  }
  owner[@"releaseStarted"] = @YES;
  NSString *profileID = [self shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [self windowIDForTabID:tabID];
  __weak ARCShaarRuntime *weakSelf = self;
  [self shaarDevToolsCall:@"Runtime.evaluate"
      params:@{@"expression": ProbeQuitHoldReleaseExpression(event)}
      capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
      profileID:profileID windowID:windowID
      completion:^(NSDictionary *, NSError *error) {
        ARCShaarRuntime *runtime = weakSelf;
        if (!runtime || !PrivateQuitHoldOwnerCurrent(runtime, tabID, owner)) {
          completion(NO);
          return;
        }
        [runtime shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_CALL tabID:tabID profileID:profileID
            windowID:windowID payload:ProbeDevToolsPayload(kProbePageDisableCommand, @{})
            completion:^(NSDictionary *, NSError *disableError) {
              ARCShaarRuntime *still = weakSelf;
              BOOL stillCurrent = still && PrivateQuitHoldOwnerCurrent(still, tabID, owner);
              if (stillCurrent) [PrivateQuitHoldOwners(still) removeObjectForKey:tabID];
              completion(error == nil && disableError == nil && stillCurrent);
            }];
      }];
}

@end

static const shaar_operation kProbePopupEvaluateOperation = static_cast<shaar_operation>(1095);
static const shaar_operation kProbePopupCaptureOperation = static_cast<shaar_operation>(1096);

static NSDictionary *ProbePopupOwner(ARCShaarRuntime *runtime, NSString *popupID) {
  if (!ProbeCaptureAllowed() || !ARCProbePopupIdentifier(popupID)) return nil;
  NSDictionary *owner = [runtime shaarExtensionPopupOwnerForID:popupID];
  if (![owner isKindOfClass:NSDictionary.class]) return nil;
  NSString *tabID = owner[@"tabID"];
  NSString *windowID = owner[@"windowID"];
  id selected = ProbeTable(runtime, "_shaarSelectedTabs")[windowID];
  if (![selected isEqual:tabID]) return nil;
  if (ARCPrivateShaarState(runtime)[@"tabs"][tabID]) return nil;
  NSView *view = [runtime viewForExtensionPopupID:popupID];
  if (!view.window || view.window.isVisible) return nil;
  for (NSWindow *window in NSApp.windows) {
    if (window.isVisible) return nil;
  }
  return owner;
}

extern "C" BOOL ARCProbeTrustedClickElementAllowed(NSString *elementID) {
  NSSet<NSString *> *allowed = [NSSet setWithArray:@[
    @"blank", @"popup", @"plain", @"performance-input",
    @"arcusis-download-probe", @"window-client-download",
    @"external-consent-probe", @"arcusis-private-quit-activation",
    @"parity-action"]];
  return [allowed containsObject:elementID];
}

@implementation ARCShaarRuntime (TrustedProbeClick)

- (void)submitTrustedProbeClickInTabID:(NSString *)tabID elementID:(NSString *)elementID
                            completion:(void (NS_SWIFT_UI_ACTOR ^)(BOOL))completion {
  if (!completion) return;
  const char *testing = std::getenv("SHAAR_ENGINE_TESTING");
  if (!testing || std::strcmp(testing, "1") != 0 ||
      !ARCProbeTrustedClickElementAllowed(elementID)) {
    completion(NO);
    return;
  }
  NSView *view = [self viewForTabID:tabID];
  if (!view.window || view.window.isVisible) {
    completion(NO);
    return;
  }
  for (NSWindow *window in NSApp.windows) {
    if (window.isVisible) {
      completion(NO);
      return;
    }
  }
  NSString *profileID = [self shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [self windowIDForTabID:tabID];
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    completion(NO);
    return;
  }
  NSString *script = [NSString stringWithFormat:
      @"(()=>{const e=document.getElementById('%@');if(!e)return null;const r=e.getBoundingClientRect();return {x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2)};})()",
      elementID];
  [self evaluateInTabID:tabID script:script completion:^(NSString *result) {
    NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *point = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSNumber *x = [point isKindOfClass:NSDictionary.class] ? point[@"x"] : nil;
    NSNumber *y = [point isKindOfClass:NSDictionary.class] ? point[@"y"] : nil;
    if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]) {
      completion(NO);
      return;
    }
    [self shaarDevToolsSubmit:1093 tabID:tabID profileID:profileID windowID:windowID
                     payload:@{@"schemaVersion": @1, @"x": x, @"y": y}
                  completion:^(NSDictionary *reply, NSError *error) {
                    if (error) NSLog(@"Trusted probe click: %@", error.localizedDescription);
                    completion(!error && [reply[@"submitted"] boolValue]);
                  }];
  }];
}

@end

@implementation ARCShaarRuntime (Verification)
- (NSDictionary *)privateQuitCDPHoldAuditForTabID:(NSString *)tabID {
  if (!ProbeCaptureAllowed()) return nil;
  NSMutableDictionary *owner = PrivateQuitHoldOwners(self)[tabID];
  if (!owner || !PrivateQuitHoldOwnerCurrent(self, tabID, owner)) return nil;
  NSString *windowID = [self windowIDForTabID:tabID];
  if (![owner[@"windowID"] isEqualToString:self.primaryWindowID] ||
      ![windowID isEqualToString:self.primaryWindowID]) return nil;
  id selected = ProbeTable(self, "_shaarSelectedTabs")[self.primaryWindowID];
  return @{@"holdCommandPending": owner[@"holdCommandPending"] ?: @NO,
           @"holdConfirmedPending": owner[@"holdConfirmedPending"] ?: @NO,
           @"selectedNormalTab": @([selected isEqual:tabID])};
}

- (void)preparePrivateQuitCancellationProbeTabID:(NSString *)tabID
                                      completion:(void (^)(BOOL))completion {
  if (!completion) return;
  if (!PrivateQuitProbeTabIsEligible(self, tabID)) {
    completion(NO);
    return;
  }
  NSString *profileID = [self shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [self windowIDForTabID:tabID];
  __weak ARCShaarRuntime *weakSelf = self;
  [self shaarDevToolsCall:@"Runtime.evaluate"
      params:@{@"expression": @"location.href", @"returnByValue": @YES}
      capability:SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER tabID:tabID
      profileID:profileID windowID:windowID
      completion:^(NSDictionary *result, NSError *error) {
        ARCShaarRuntime *runtime = weakSelf;
        NSString *href = ProbeEvaluateString(result);
        if (!runtime || error || !PrivateQuitProbeTabIsEligible(runtime, tabID) ||
            !ARCProbeLoopbackDocumentURL(href)) {
          completion(NO);
          return;
        }
        [runtime shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_CALL tabID:tabID profileID:profileID
            windowID:windowID payload:ProbeDevToolsPayload(kProbePageDisableCommand, @{})
            completion:^(NSDictionary *, NSError *probeError) {
              ARCShaarRuntime *ready = weakSelf;
              if (!ready || !PrivateQuitProbeTabIsEligible(ready, tabID) ||
                  ARCProbeDevToolsCommandIsUnknown(probeError.localizedDescription)) {
                completion(NO);
                return;
              }
              [ready beginPrivateQuitCDPHoldForTabID:tabID completion:completion];
            }];
      }];
}

- (void)cancelPrivateQuitDialogForProbeTabID:(NSString *)tabID
                                  completion:(void (^)(BOOL))completion {
  if (!completion) return;
  NSMutableDictionary *owner = PrivateQuitHoldOwners(self)[tabID];
  NSString *rejection = PrivateQuitCancelRejection(self, tabID, owner);
  if (rejection) {
    RecordPrivateQuitDialogResult(self, [@"rejected-" stringByAppendingString:rejection]);
    completion(NO);
    return;
  }
  NSString *profileID = [self shaarDevToolsProfileIDForTabID:tabID];
  NSString *windowID = [self windowIDForTabID:tabID];
  __weak ARCShaarRuntime *weakSelf = self;
  [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_CALL tabID:tabID profileID:profileID
      windowID:windowID
      payload:ProbeDevToolsPayload(kProbePageHandleJavaScriptDialogCommand, @{@"accept": @NO})
      completion:^(NSDictionary *, NSError *error) {
        ARCShaarRuntime *runtime = weakSelf;
        if (!runtime) {
          completion(NO);
          return;
        }
        BOOL ownerCurrent = PrivateQuitHoldOwnerCurrent(runtime, tabID, owner);
        RecordPrivateQuitDialogResult(runtime, ARCProbePrivateQuitDialogResult(
            ownerCurrent, error.localizedDescription));
        ARCCompletePrivateQuitDialogCancellation(ownerCurrent, error.localizedDescription, ^{
          [runtime endPrivateQuitCDPHoldForTabID:tabID owner:owner completion:^(BOOL ended) {
            completion(ended);
          }];
        }, ^{
          completion(NO);
        });
      }];
}

- (void)evaluateProbePopupID:(NSString *)popupID script:(NSString *)script
                 completion:(void (^)(NSString *))completion {
  if (!completion) return;
  NSDictionary *owner = ProbePopupOwner(self, popupID);
  if (!owner || !ARCProbePopupExpression(script)) {
    completion(nil);
    return;
  }
  NSString *tabID = owner[@"tabID"];
  NSString *profileID = owner[@"profileID"];
  NSString *windowID = owner[@"windowID"];
  __weak ARCShaarRuntime *weakRuntime = self;
  [self shaarDevToolsSubmit:kProbePopupEvaluateOperation tabID:tabID profileID:profileID
                  windowID:windowID
                   payload:@{@"schemaVersion": @1, @"popupId": popupID, @"expression": script}
                completion:^(NSDictionary *reply, NSError *error) {
    ARCShaarRuntime *runtime = weakRuntime;
    NSDictionary *current = runtime ? ProbePopupOwner(runtime, popupID) : nil;
    if (error || ![current isEqualToDictionary:owner]) {
      completion(nil);
      return;
    }
    completion(ARCProbeEvaluationJSON(reply));
  }];
}

- (void)captureProbePopupID:(NSString *)popupID completion:(void (^)(NSData *))completion {
  if (!completion) return;
  NSDictionary *owner = ProbePopupOwner(self, popupID);
  if (!owner) {
    completion(nil);
    return;
  }
  NSString *tabID = owner[@"tabID"];
  NSString *profileID = owner[@"profileID"];
  NSString *windowID = owner[@"windowID"];
  __weak ARCShaarRuntime *weakRuntime = self;
  [self shaarDevToolsSubmit:kProbePopupCaptureOperation tabID:tabID profileID:profileID
                  windowID:windowID
                   payload:@{@"schemaVersion": @1, @"popupId": popupID}
                completion:^(NSDictionary *reply, NSError *error) {
    ARCShaarRuntime *runtime = weakRuntime;
    NSDictionary *current = runtime ? ProbePopupOwner(runtime, popupID) : nil;
    if (error || ![current isEqualToDictionary:owner]) {
      completion(nil);
      return;
    }
    completion(ARCProbePNGFromDevToolsResult(reply));
  }];
}

- (void)clickProbeElementInTabID:(NSString *)tabID elementID:(NSString *)elementID
                    completion:(void (^)(BOOL))completion {
  if (!completion) return;
  if (!ProbeCaptureAllowed()) {
    completion(NO);
    return;
  }
  [self submitTrustedProbeClickInTabID:tabID elementID:elementID completion:completion];
}
- (NSDictionary *)privateNavigationProbeAuditForTabID:(NSString *)tabID {
  if (!ProbeCaptureAllowed()) return nil;
  NSDictionary *tab = ARCPrivateShaarState(self)[@"tabs"][tabID];
  if (!tab) return nil;
  return @{@"stage": tab[@"navigationStage"] ?: @"none",
           @"generation": tab[@"requestGeneration"] ?: @0,
           @"requestedURL": tab[@"requestedURL"] ?: @"none",
           @"observedURL": tab[@"url"] ?: @"none",
           @"lastEventPhase": tab[@"navigationPhase"] ?: @"none"};
}
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
