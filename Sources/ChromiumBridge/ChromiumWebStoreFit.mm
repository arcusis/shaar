// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumWebStoreFit.h"
#import "include/ChromiumBridge.h"
#import "ChromiumShaarExtensionsInternal.h"
#import "../../ThirdParty/ArdiaCore/ArdiaCore.h"
#include <algorithm>
#include <cmath>

static const double WebStoreMinimumZoom = 0.67;
static const double ZoomTolerance = 0.005;
static const NSTimeInterval FitDelay = 0.1;
static NSString *const RequiredWidthScript =
  @"(()=>{const min=e=>e?parseFloat(getComputedStyle(e).minWidth)||0:0;"
   "return Math.max(min(document.documentElement),min(document.body));})()";

double ARCWebStoreFitZoom(double viewportWidth, double requiredWidth) {
  if (!std::isfinite(viewportWidth) || !std::isfinite(requiredWidth) || viewportWidth <= 0 ||
      requiredWidth <= viewportWidth) return 1;
  // Round down so the zoomed layout width never lands a fraction of a pixel short.
  double fit = std::floor(viewportWidth / requiredWidth * 1000) / 1000;
  return std::max(fit, WebStoreMinimumZoom);
}

@interface ARCWebStoreFitState : NSObject
@property(nonatomic) NSUInteger generation;
@property(nonatomic) double appliedZoom;
@property(nonatomic) BOOL manual;
@property(nonatomic, strong, nullable) id frameObserver;
@property(nonatomic, weak, nullable) ARCShaarRuntime *shaarRuntime;
@property(nonatomic, copy, nullable) NSString *shaarURL;
@property(nonatomic, copy, nullable) NSString *shaarProfileID;
@end

@implementation ARCWebStoreFitState
- (void)dealloc {
  if (_frameObserver) [NSNotificationCenter.defaultCenter removeObserver:_frameObserver];
}
@end

@implementation ARCWebStoreFit {
  BOOL _testing;
  ARCWebStoreFitEvaluator _evaluator;
  NSMapTable<ArdiaCoreTab *, ARCWebStoreFitState *> *_states;
  NSMutableDictionary<NSString *, ARCWebStoreFitState *> *_shaarStates;
}

- (instancetype)initWithTesting:(BOOL)testing evaluator:(ARCWebStoreFitEvaluator)evaluator {
  if (!(self = [super init])) return nil;
  _testing = testing;
  _evaluator = [evaluator copy];
  _states = [NSMapTable weakToStrongObjectsMapTable];
  _shaarStates = [NSMutableDictionary dictionary];
  return self;
}

- (void)tabDidNavigate:(ArdiaCoreTab *)tab {
  if (tab.closed || ![self fitsTab:tab]) {
    [self forgetTab:tab];
    return;
  }
  ARCWebStoreFitState *state = [self stateForTab:tab];
  state.generation += 1;
  state.appliedZoom = 0;
  state.manual = NO;
  [self scheduleTab:tab];
}

- (void)tabDidChangeLoading:(ArdiaCoreTab *)tab {
  if (!tab.loading && [_states objectForKey:tab]) [self scheduleTab:tab];
}

- (void)tabDidChangeZoom:(ArdiaCoreTab *)tab {
  ARCWebStoreFitState *state = [_states objectForKey:tab];
  if (state.appliedZoom > 0 && std::fabs(tab.zoomFactor - state.appliedZoom) > ZoomTolerance) {
    state.manual = YES;
  }
}

- (void)tabWillClose:(ArdiaCoreTab *)tab {
  [self forgetTab:tab];
}

- (void)forgetTab:(ArdiaCoreTab *)tab {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fitTab:) object:tab];
  [_states removeObjectForKey:tab];
}

/// Zoom applies to the committed host, while the visible URL leads during a navigation;
/// both must be the store so another site's zoom is never changed.
- (BOOL)fitsTab:(ArdiaCoreTab *)tab {
  NSString *url = tab.url ?: @"";
  return [self isWebStoreURL:url] && [tab.committedOrigin isEqualToString:[tab.class originForURL:url]];
}

/// Chrome Web Store only; probes use an authored loopback page with the same fixed body width.
- (BOOL)isWebStoreURL:(NSString *)string {
  NSURLComponents *url = [NSURLComponents componentsWithString:string];
  NSString *host = url.host.lowercaseString;
  if ([url.scheme isEqualToString:@"https"] && [host isEqualToString:@"chromewebstore.google.com"]) {
    return YES;
  }
  return _testing && [url.scheme isEqualToString:@"http"] && [host isEqualToString:@"127.0.0.1"] &&
    [url.path hasPrefix:@"/web-store-fit"];
}

- (ARCWebStoreFitState *)stateForTab:(ArdiaCoreTab *)tab {
  ARCWebStoreFitState *state = [_states objectForKey:tab];
  if (state) return state;
  state = [ARCWebStoreFitState new];
  __weak ARCWebStoreFit *weakSelf = self;
  __weak ArdiaCoreTab *weakTab = tab;
  tab.view.postsFrameChangedNotifications = YES;
  // Window resize, sidebar toggle and split all reach the page view as a frame change.
  state.frameObserver = [NSNotificationCenter.defaultCenter
    addObserverForName:NSViewFrameDidChangeNotification object:tab.view queue:nil
            usingBlock:^(NSNotification *notification) {
    ArdiaCoreTab *current = weakTab;
    if (current) [weakSelf scheduleTab:current];
  }];
  [_states setObject:state forKey:tab];
  return state;
}

/// Coalesces live resize into one measurement after the frame settles.
- (void)scheduleTab:(ArdiaCoreTab *)tab {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fitTab:) object:tab];
  [self performSelector:@selector(fitTab:) withObject:tab afterDelay:FitDelay];
}

- (void)fitTab:(ArdiaCoreTab *)tab {
  ARCWebStoreFitState *state = [_states objectForKey:tab];
  if (!state || state.manual || tab.closed || ![self fitsTab:tab]) return;
  NSUInteger generation = state.generation;
  _evaluator(tab, RequiredWidthScript, ^(NSString *json) {
    [self applyRequiredWidth:json toTab:tab state:state generation:generation];
  });
}

- (void)applyRequiredWidth:(NSString *)json
                     toTab:(ArdiaCoreTab *)tab
                     state:(ARCWebStoreFitState *)state
                generation:(NSUInteger)generation {
  BOOL current = [_states objectForKey:tab] == state && state.generation == generation;
  double viewport = NSWidth(tab.view.bounds);
  if (!json || !current || state.manual || tab.closed || viewport <= 0 || ![self fitsTab:tab]) return;
  double zoom = ARCWebStoreFitZoom(viewport, json.doubleValue);
  state.appliedZoom = zoom;
  if (std::fabs(tab.zoomFactor - zoom) > ZoomTolerance) tab.zoomFactor = zoom;
}

- (void)shaarTabDidReceiveEvent:(NSDictionary *)event tabID:(NSString *)tabID runtime:(ARCShaarRuntime *)runtime {
  NSString *phase = event[@"phase"];
  NSString *url = event[@"url"];
  if (![url isKindOfClass:NSString.class] || ![self isWebStoreURL:url]) {
    [self shaarTabWillCloseID:tabID];
    return;
  }
  ARCWebStoreFitState *state = _shaarStates[tabID];
  if (!state) {
    state = [ARCWebStoreFitState new];
    _shaarStates[tabID] = state;
  }
  state.shaarRuntime = runtime;
  state.shaarURL = url;
  state.shaarProfileID = [runtime shaarProfileIDForTabID:tabID];
  if ([phase isEqualToString:@"started"] || [phase isEqualToString:@"committed"]) {
    state.generation++;
    state.appliedZoom = 0;
    state.manual = NO;
  }
  NSView *view = [runtime viewForTabID:tabID];
  if (view && !state.frameObserver) {
    view.postsFrameChangedNotifications = YES;
    __weak ARCWebStoreFit *weakSelf = self;
    state.frameObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSViewFrameDidChangeNotification object:view queue:nil
                usingBlock:^(NSNotification *notification) {
      [weakSelf scheduleShaarTabID:tabID];
    }];
  }
  if (![event[@"loading"] boolValue]) [self scheduleShaarTabID:tabID];
}

- (void)shaarTabWillCloseID:(NSString *)tabID {
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(fitShaarTabID:) object:tabID];
  [_shaarStates removeObjectForKey:tabID];
}

- (void)scheduleShaarTabID:(NSString *)tabID {
  ARCWebStoreFitState *state = _shaarStates[tabID];
  if (!state || state.manual) return;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(fitShaarTabID:) object:tabID];
  [self performSelector:@selector(fitShaarTabID:) withObject:tabID afterDelay:FitDelay];
}

- (void)fitShaarTabID:(NSString *)tabID {
  ARCWebStoreFitState *state = _shaarStates[tabID];
  ARCShaarRuntime *runtime = state.shaarRuntime;
  NSView *view = [runtime viewForTabID:tabID];
  if (!state || !runtime || !view || state.manual || !state.shaarProfileID ||
      ![self isWebStoreURL:state.shaarURL]) return;
  double width = NSWidth(view.bounds);
  if (width <= 0) return;
  // The store's current fixed body minimum is 1280 CSS pixels. The native
  // operation validates the committed host before changing its zoom.
  double zoom = ARCWebStoreFitZoom(width, 1280);
  NSUInteger generation = state.generation;
  [runtime shaarSubmitExtensionOperation:SHAAR_OP_EXTENSION_WEB_STORE_ZOOM
      profileID:state.shaarProfileID tabID:tabID
      payload:@{@"schemaVersion": @1, @"zoomFactor": @(zoom),
                @"appliedZoom": @(state.appliedZoom)}
      completion:^(NSString *json, shaar_error_code code) {
        if (code != SHAAR_OK || !json || self->_shaarStates[tabID] != state ||
            state.generation != generation) return;
        NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:
            [json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![reply[@"schemaVersion"] isEqual:@1]) return;
        state.manual = [reply[@"manual"] boolValue];
        if (!state.manual) state.appliedZoom = [reply[@"zoomFactor"] doubleValue];
      }];
}

@end
