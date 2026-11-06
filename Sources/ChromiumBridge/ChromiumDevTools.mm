// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarPrivateSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <climits>
#include <dlfcn.h>
#include <cstring>
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

namespace {
char kShaarFrontendViews;
char kShaarDockTabs;

NSMutableDictionary<NSString *, NSView *> *ShaarFrontendViews(ARCShaarRuntime *runtime) {
  NSMutableDictionary *views = objc_getAssociatedObject(runtime, &kShaarFrontendViews);
  if (!views) {
    views = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, &kShaarFrontendViews, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return views;
}

NSMutableSet<NSString *> *ShaarDockTabs(ARCShaarRuntime *runtime) {
  NSMutableSet *tabs = objc_getAssociatedObject(runtime, &kShaarDockTabs);
  if (!tabs) {
    tabs = [NSMutableSet set];
    objc_setAssociatedObject(runtime, &kShaarDockTabs, tabs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return tabs;
}
NSDictionary *ShaarTable(id runtime, const char *name) {
  Ivar field = class_getInstanceVariable([runtime class], name);
  return field ? object_getIvar(runtime, field) : nil;
}

shaar_engine *ShaarEngineHandle(id runtime) {
  Ivar field = class_getInstanceVariable([runtime class], "_shaarEngine");
  if (!field) return nullptr;
  void *handle = nullptr;
  std::memcpy(&handle, reinterpret_cast<char *>((__bridge void *)runtime) + ivar_getOffset(field),
              sizeof(handle));
  return static_cast<shaar_engine *>(handle);
}

uint64_t ShaarRequestID(id runtime) {
  Ivar field = class_getInstanceVariable([runtime class], "_nextRequestID");
  if (!field) return 0;
  auto *next = reinterpret_cast<uint64_t *>(reinterpret_cast<char *>((__bridge void *)runtime) +
                                            ivar_getOffset(field));
  return (*next)++;
}

NSError *ShaarDevToolsError(NSString *message) {
  return [NSError errorWithDomain:@"org.arcusis.shaar.engine.devtools" code:1
                         userInfo:@{NSLocalizedDescriptionKey: message ?: @"DevTools request failed."}];
}

NSString *ShaarErrorMessage(shaar_bytes bytes) {
  if (!bytes.data || !bytes.size) return @"DevTools request failed.";
  return [[NSString alloc] initWithBytes:bytes.data length:bytes.size
                               encoding:NSUTF8StringEncoding] ?: @"DevTools request failed.";
}

const NSArray<NSString *> *ShaarMethods() {
  static NSArray<NSString *> *methods;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    methods = @[@"Runtime.evaluate", @"Runtime.releaseObject", @"Runtime.getProperties",
      @"Runtime.releaseObjectGroup", @"DOM.enable", @"DOM.getDocument", @"DOM.requestNode",
      @"DOM.getBoxModel", @"CSS.enable", @"CSS.getPlatformFontsForNode",
      @"CSS.getBackgroundColors", @"CSS.getMatchedStylesForNode", @"CSS.getComputedStyleForNode",
      @"CSS.getStyleSheetText", @"Page.enable", @"Page.getResourceTree",
      @"Page.getResourceContent", @"Page.captureScreenshot", @"Overlay.enable",
      @"Overlay.disable", @"Overlay.setShowGridOverlays", @"Overlay.setShowFlexOverlays",
      @"Overlay.getGridHighlightObjectsForTest", @"DOM.describeNode",
      @"Accessibility.getPartialAXTree", @"Emulation.setDeviceMetricsOverride",
      @"Emulation.clearDeviceMetricsOverride", @"Network.enable",
      @"Network.emulateNetworkConditions", @"Emulation.setCPUThrottlingRate",
      @"Emulation.setGeolocationOverride", @"Emulation.clearGeolocationOverride",
      @"Emulation.setTimezoneOverride", @"Emulation.setLocaleOverride",
      @"Emulation.setUserAgentOverride", @"Emulation.setEmulatedMedia", @"Performance.enable",
      @"Performance.getMetrics", @"Page.addScriptToEvaluateOnNewDocument",
      @"Page.removeScriptToEvaluateOnNewDocument", @"Network.getCookies", @"Network.setCookie",
      @"Network.deleteCookies"];
  });
  return methods;
}

BOOL SubmitShaarDevTools(ARCShaarRuntime *runtime, shaar_scope scope,
                         shaar_window *window, shaar_tab *tab,
                         NSUInteger operation, NSDictionary *payload,
                         void (^completion)(NSDictionary *, NSError *)) {
  auto submit = reinterpret_cast<decltype(&shaar_submit)>(dlsym(RTLD_DEFAULT, "shaar_submit"));
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!submit || !json || ![runtime privateEngineHandle]) {
    if (completion) completion(nil, ShaarDevToolsError(@"Shaar DevTools is unavailable."));
    return NO;
  }
  uint64_t requestID = ShaarRequestID(runtime);
  if (!requestID || requestID > INT_MAX) {
    if (completion) completion(nil, ShaarDevToolsError(@"Shaar DevTools request ID is unavailable."));
    return NO;
  }
  void (^reply)(NSDictionary *, NSError *) = [completion copy];
  if (!reply) reply = ^(NSDictionary *, NSError *) {};
  void *context = (__bridge_retained void *)reply;
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_error_code status = submit([runtime privateEngineHandle], scope, window, tab,
      static_cast<shaar_operation>(operation), {(const char *)json.bytes, json.length},
      requestID, [](void *context, const shaar_result *result) {
        void (^finish)(NSDictionary *, NSError *) = (__bridge_transfer id)context;
        if (!result) { finish(nil, ShaarDevToolsError(@"DevTools returned no reply.")); return; }
        if (result->error.code != SHAAR_OK) {
          finish(nil, ShaarDevToolsError(ShaarErrorMessage(result->error.message)));
          return;
        }
        NSData *data = [NSData dataWithBytes:result->payload_json.data ?: ""
                                     length:result->payload_json.size];
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![envelope isKindOfClass:NSDictionary.class] ||
            ![envelope[@"schemaVersion"] isEqual:@1]) {
          finish(nil, ShaarDevToolsError(@"DevTools returned an invalid reply."));
          return;
        }
        finish([envelope[@"result"] isKindOfClass:NSDictionary.class] ? envelope[@"result"] : envelope, nil);
      }, context, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    if (completion) completion(nil, ShaarDevToolsError(ShaarErrorMessage(error.message)));
    return NO;
  }
  return YES;
}

}  // namespace

@interface ARCShaarRuntime (NativeFrontend)
- (NSView *)shaarNativeFrontendViewForTabID:(NSString *)tabID
                                 profileID:(NSString *)profileID windowID:(NSString *)windowID;
@end

@implementation ARCShaarRuntime (DevToolsTransport)

- (void)viewportRequest:(NSUInteger)operation tabID:(NSString *)tabID
              profileID:(NSString *)profileID windowID:(NSString *)windowID
              contextID:(NSString *)contextID payload:(NSDictionary<NSString *, id> *)payload
             completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  if (operation < SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN ||
      operation > SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME) {
    completion(nil, ShaarDevToolsError(@"This Viewports operation is unavailable."));
    return;
  }
  if (contextID.length) {
    [self shaarPrivateDevToolsSubmit:operation tabID:tabID windowID:windowID
                          contextID:contextID payload:payload completion:completion];
  } else {
    [self shaarDevToolsSubmit:operation tabID:tabID profileID:profileID
                    windowID:windowID payload:payload completion:completion];
  }
}

- (void)agentBridgeRequest:(NSUInteger)operation forTabID:(NSString *)tabID
                 profileID:(NSString *)profileID windowID:(NSString *)windowID
                completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  if (operation != SHAAR_OP_DEVTOOLS_CONTROL_ENABLE &&
      operation != SHAAR_OP_DEVTOOLS_CONTROL_DISABLE &&
      operation != SHAAR_OP_DEVTOOLS_CONTROL_STATUS) {
    completion(nil, ShaarDevToolsError(@"This agent bridge operation is unavailable."));
    return;
  }
  [self shaarDevToolsSubmit:operation tabID:tabID profileID:profileID windowID:windowID
                   payload:@{@"schemaVersion": @1} completion:completion];
}

- (NSString *)shaarDevToolsProfileIDForTabID:(NSString *)tabID {
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  return [self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]
    ? profileID : nil;
}

- (BOOL)shaarDevToolsOwnsTabID:(NSString *)tabID profileID:(NSString *)profileID
                    windowID:(NSString *)windowID {
  if (!tabID.length || !profileID.length || !windowID.length) return NO;
  return ShaarEngineHandle(self) && [ShaarTable(self, "_shaarTabProfiles")[tabID] isEqual:profileID] &&
         [ShaarTable(self, "_shaarTabWindows")[tabID] isEqual:windowID] &&
         ShaarTable(self, "_shaarTabs")[tabID] && ShaarTable(self, "_shaarWindows")[windowID] &&
         ShaarTable(self, "_shaarProfiles")[profileID];
}

- (BOOL)shaarDevToolsSubmit:(NSUInteger)operation tabID:(NSString *)tabID
                 profileID:(NSString *)profileID windowID:(NSString *)windowID
                   payload:(NSDictionary *)payload
                completion:(void (^)(NSDictionary *, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Shaar DevTools requires the main thread");
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    if (completion) completion(nil, ShaarDevToolsError(@"The DevTools target is no longer available."));
    return NO;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = static_cast<shaar_profile *>(
      [ShaarTable(self, "_shaarProfiles")[profileID] pointerValue]);
  auto *window = static_cast<shaar_window *>(
      [ShaarTable(self, "_shaarWindows")[windowID] pointerValue]);
  auto *tab = static_cast<shaar_tab *>([ShaarTable(self, "_shaarTabs")[tabID] pointerValue]);
  return SubmitShaarDevTools(self, scope, window, tab, operation, payload, completion);
}

- (void)shaarDevToolsCall:(NSString *)method params:(NSDictionary *)params
              capability:(NSUInteger)capability tabID:(NSString *)tabID
               profileID:(NSString *)profileID windowID:(NSString *)windowID
              completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  NSUInteger index = [ShaarMethods() indexOfObject:method];
  if (index == NSNotFound || (capability != SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR &&
                             capability != SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER)) {
    completion(nil, ShaarDevToolsError(@"This DevTools command is unavailable."));
    return;
  }
  NSDictionary *payload = @{@"schemaVersion": @1, @"capability": @(capability),
                            @"command": @(index + 1), @"params": params ?: @{}};
  [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_CALL tabID:tabID profileID:profileID
                   windowID:windowID payload:payload completion:completion];
}

- (void)shaarPrivateDevToolsCall:(NSString *)method params:(NSDictionary *)params
                     capability:(NSUInteger)capability tabID:(NSString *)tabID
                       windowID:(NSString *)windowID contextID:(NSString *)contextID
                     completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary<NSString *, id> *, NSError *))completion {
  NSAssert(NSThread.isMainThread, @"Shaar DevTools requires the main thread");
  NSUInteger index = [ShaarMethods() indexOfObject:method];
  if (index == NSNotFound || (capability != SHAAR_DEVTOOLS_CAPABILITY_INSPECTOR &&
                             capability != SHAAR_DEVTOOLS_CAPABILITY_DEVELOPER)) {
    completion(nil, ShaarDevToolsError(@"This DevTools command is unavailable."));
    return;
  }
  NSDictionary *payload = @{@"schemaVersion": @1, @"capability": @(capability),
                            @"command": @(index + 1), @"params": params ?: @{}};
  [self shaarPrivateDevToolsSubmit:SHAAR_OP_DEVTOOLS_CALL tabID:tabID
                         windowID:windowID contextID:contextID payload:payload completion:completion];
}

- (BOOL)shaarPrivateDevToolsSubmit:(NSUInteger)operation tabID:(NSString *)tabID
                        windowID:(NSString *)windowID contextID:(NSString *)contextID
                         payload:(NSDictionary *)payload
                      completion:(void (^)(NSDictionary *, NSError *))completion {
  if (![self privateTabOwned:tabID windowID:windowID contextID:contextID]) {
    completion(nil, ShaarDevToolsError(@"The private DevTools target is no longer available."));
    return NO;
  }
  NSDictionary *state = ARCPrivateShaarState(self);
  NSDictionary *context = state[@"contexts"][contextID];
  NSDictionary *window = state[@"windows"][windowID];
  NSDictionary *tab = state[@"tabs"][tabID];
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.private_session = static_cast<shaar_private_session *>(
      [context[@"session"] pointerValue]);
  auto *windowHandle = static_cast<shaar_window *>([window[@"handle"] pointerValue]);
  auto *tabHandle = static_cast<shaar_tab *>([tab[@"handle"] pointerValue]);
  return SubmitShaarDevTools(self, scope, windowHandle, tabHandle,
                             operation, payload, completion);
}

- (void)toggleDevToolsForPrivateTabID:(NSString *)tabID windowID:(NSString *)windowID
                          contextID:(NSString *)contextID
                         completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError *))completion {
  NSDictionary *payload = @{@"schemaVersion": @1};
  [self shaarPrivateDevToolsSubmit:SHAAR_OP_DEVTOOLS_UI_STATE tabID:tabID
                         windowID:windowID contextID:contextID payload:payload
                      completion:^(NSDictionary *result, NSError *error) {
    if (error) { completion(error); return; }
    if (![result[@"open"] isKindOfClass:NSNumber.class]) {
      completion(ShaarDevToolsError(@"DevTools returned an invalid reply."));
      return;
    }
    NSUInteger operation = [result[@"open"] boolValue] ? SHAAR_OP_DEVTOOLS_UI_CLOSE : SHAAR_OP_DEVTOOLS_UI_SHOW;
    [self shaarPrivateDevToolsSubmit:operation tabID:tabID windowID:windowID
                          contextID:contextID payload:payload
                         completion:^(NSDictionary *reply, NSError *failure) { completion(failure); }];
  }];
}

- (NSView *)devToolsViewForTabID:(NSString *)tabID {
  if (!tabID.length) return nil;
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    [ShaarFrontendViews(self) removeObjectForKey:tabID];
    [ShaarDockTabs(self) removeObject:tabID];
    return nil;
  }
  NSView *native = [self shaarNativeFrontendViewForTabID:tabID
                                             profileID:profileID windowID:windowID];
  if (native) [ShaarDockTabs(self) addObject:tabID];
  if ([ShaarDockTabs(self) containsObject:tabID]) return native;
  // Published shaar.13 opens an undocked native window and exposes no view.
  return ShaarFrontendViews(self)[tabID];
}

- (NSView *)shaarNativeFrontendViewForTabID:(NSString *)tabID
                                 profileID:(NSString *)profileID windowID:(NSString *)windowID {
  auto frontend = reinterpret_cast<decltype(&shaar_devtools_frontend_view)>(
      dlsym(RTLD_DEFAULT, "shaar_devtools_frontend_view"));
  if (!frontend) return nil;
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = (shaar_profile *)[ShaarTable(self, "_shaarProfiles")[profileID] pointerValue];
  auto *window = (shaar_window *)[ShaarTable(self, "_shaarWindows")[windowID] pointerValue];
  auto *tab = (shaar_tab *)[ShaarTable(self, "_shaarTabs")[tabID] pointerValue];
  if (!scope.profile || !window || !tab) return nil;
  return (__bridge NSView *)frontend(ShaarEngineHandle(self), scope, window, tab);
}

- (BOOL)showDevToolsForTabID:(NSString *)tabID {
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  BOOL accepted = [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_UI_SHOW tabID:tabID
                                 profileID:profileID windowID:windowID
                                   payload:@{@"schemaVersion": @1}
                                completion:^(NSDictionary *result, NSError *error) {
    if (error) {
      [ShaarFrontendViews(self) removeObjectForKey:tabID];
      if (self.onNotice) self.onNotice(error.localizedDescription);
      return;
    }
    ShaarFrontendViews(self)[tabID] = [NSView new];
    if ([self shaarNativeFrontendViewForTabID:tabID profileID:profileID windowID:windowID]) {
      [ShaarDockTabs(self) addObject:tabID];
    }
  }];
  return accepted;
}

- (void)toggleDevToolsForTabID:(NSString *)tabID
                   completion:(void (NS_SWIFT_UI_ACTOR ^)(NSError *))completion {
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  NSDictionary *payload = @{@"schemaVersion": @1};
  [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_UI_STATE tabID:tabID profileID:profileID
                   windowID:windowID payload:payload
                 completion:^(NSDictionary *result, NSError *error) {
    if (error) { completion(error); return; }
    if (![result[@"open"] isKindOfClass:NSNumber.class]) {
      completion(ShaarDevToolsError(@"DevTools returned an invalid reply."));
      return;
    }
    BOOL open = ![result[@"open"] boolValue];
    NSUInteger operation = open ? SHAAR_OP_DEVTOOLS_UI_SHOW : SHAAR_OP_DEVTOOLS_UI_CLOSE;
    [self shaarDevToolsSubmit:operation tabID:tabID profileID:profileID windowID:windowID
                      payload:payload completion:^(NSDictionary *reply, NSError *failure) {
      if (!failure) {
        if (open) {
          ShaarFrontendViews(self)[tabID] = [NSView new];
          if ([self shaarNativeFrontendViewForTabID:tabID
                                         profileID:profileID windowID:windowID]) {
            [ShaarDockTabs(self) addObject:tabID];
          }
        } else {
          [ShaarFrontendViews(self) removeObjectForKey:tabID];
          [ShaarDockTabs(self) removeObject:tabID];
        }
      }
      completion(failure);
    }];
  }];
}

- (BOOL)closeDevToolsForTabID:(NSString *)tabID {
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  NSView *marker = ShaarFrontendViews(self)[tabID];
  BOOL accepted = [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_UI_CLOSE tabID:tabID
                                 profileID:profileID windowID:windowID
                                   payload:@{@"schemaVersion": @1}
                                completion:^(NSDictionary *result, NSError *error) {
    if (error && marker) ShaarFrontendViews(self)[tabID] = marker;
  }];
  if (accepted) {
    [ShaarFrontendViews(self) removeObjectForKey:tabID];
    [ShaarDockTabs(self) removeObject:tabID];
  }
  return accepted;
}

@end
