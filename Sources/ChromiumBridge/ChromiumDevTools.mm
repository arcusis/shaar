// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <cstring>
#include "../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

namespace {
char kShaarFrontendViews;

NSMutableDictionary<NSString *, NSView *> *ShaarFrontendViews(ARCShaarRuntime *runtime) {
  NSMutableDictionary *views = objc_getAssociatedObject(runtime, &kShaarFrontendViews);
  if (!views) {
    views = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(runtime, &kShaarFrontendViews, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return views;
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

}  // namespace

@implementation ARCShaarRuntime (DevToolsTransport)

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
  auto submit = reinterpret_cast<decltype(&shaar_submit)>(dlsym(RTLD_DEFAULT, "shaar_submit"));
  NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  if (!submit || !json) {
    if (completion) completion(nil, ShaarDevToolsError(@"Shaar DevTools is unavailable."));
    return NO;
  }
  shaar_scope scope = {};
  scope.size = sizeof(scope);
  scope.profile = static_cast<shaar_profile *>(
      [ShaarTable(self, "_shaarProfiles")[profileID] pointerValue]);
  auto *window = static_cast<shaar_window *>(
      [ShaarTable(self, "_shaarWindows")[windowID] pointerValue]);
  auto *tab = static_cast<shaar_tab *>([ShaarTable(self, "_shaarTabs")[tabID] pointerValue]);
  uint64_t requestID = ShaarRequestID(self);
  if (!requestID) {
    if (completion) completion(nil, ShaarDevToolsError(@"Shaar DevTools request ID is unavailable."));
    return NO;
  }
  void (^reply)(NSDictionary *, NSError *) = [completion copy];
  if (!reply) reply = ^(NSDictionary *, NSError *) {};
  void *context = (__bridge_retained void *)reply;
  shaar_error error = {};
  error.size = sizeof(error);
  shaar_error_code status = submit(ShaarEngineHandle(self), scope, window, tab,
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
        finish([envelope[@"result"] isKindOfClass:NSDictionary.class] ? envelope[@"result"] : @{}, nil);
      }, context, &error);
  if (status != SHAAR_OK) {
    CFBridgingRelease(context);
    if (completion) completion(nil, ShaarDevToolsError(ShaarErrorMessage(error.message)));
    return NO;
  }
  return YES;
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

- (NSView *)devToolsViewForTabID:(NSString *)tabID {
  if (!tabID.length) return nil;
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  if (![self shaarDevToolsOwnsTabID:tabID profileID:profileID windowID:windowID]) {
    [ShaarFrontendViews(self) removeObjectForKey:tabID];
    return nil;
  }
  // The ABI has no borrowed frontend view. This private marker exposes open state
  // to the app's existing toggle and developer tools model.
  return ShaarFrontendViews(self)[tabID];
}

- (BOOL)showDevToolsForTabID:(NSString *)tabID {
  NSString *profileID = ShaarTable(self, "_shaarTabProfiles")[tabID];
  NSString *windowID = ShaarTable(self, "_shaarTabWindows")[tabID];
  BOOL accepted = [self shaarDevToolsSubmit:SHAAR_OP_DEVTOOLS_UI_SHOW tabID:tabID
                                 profileID:profileID windowID:windowID
                                   payload:@{@"schemaVersion": @1}
                                completion:^(NSDictionary *result, NSError *error) {
    if (error) [ShaarFrontendViews(self) removeObjectForKey:tabID];
  }];
  if (accepted) ShaarFrontendViews(self)[tabID] = [NSView new];
  return accepted;
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
  if (accepted) [ShaarFrontendViews(self) removeObjectForKey:tabID];
  return accepted;
}

@end
