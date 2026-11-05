// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumWebStoreFit.h"
#import "include/ChromiumBridge.h"
#import "ChromiumShaarExtensionsInternal.h"
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
  NSMutableDictionary<NSString *, ARCWebStoreFitState *> *_shaarStates;
}

- (instancetype)initWithTesting:(BOOL)testing {
  if (!(self = [super init])) return nil;
  _testing = testing;
  _shaarStates = [NSMutableDictionary dictionary];
  return self;
}

- (BOOL)isWebStoreURL:(NSString *)string {
  NSURLComponents *url = [NSURLComponents componentsWithString:string];
  NSString *host = url.host.lowercaseString;
  if ([url.scheme isEqualToString:@"https"] && [host isEqualToString:@"chromewebstore.google.com"]) {
    return YES;
  }
  return _testing && [url.scheme isEqualToString:@"http"] && [host isEqualToString:@"127.0.0.1"] &&
    [url.path hasPrefix:@"/web-store-fit"];
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
