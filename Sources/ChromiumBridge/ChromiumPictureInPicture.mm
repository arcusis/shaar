// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import "ChromiumShaarFeatureTransport.h"
#include <cmath>

// Runs with a user gesture so Chromium accepts the request. It picks the largest playing
// video the page allows in picture-in-picture and opens Chromium's own video window.
static NSString *const ARCEnterPictureInPictureScript =
  @"(()=>{const videos=[...document.querySelectorAll('video')].filter(v=>!v.paused&&!v.ended&&"
   "v.readyState>1&&v.videoWidth>0&&!v.disablePictureInPicture);"
   "videos.sort((a,b)=>b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight);"
   "if(!videos.length)return {requested:false};"
   "if(document.pictureInPictureElement!==videos[0])videos[0].requestPictureInPicture().catch(()=>{});"
   "return {requested:true};})()";

static NSString *const ARCExitPictureInPictureScript =
  @"(()=>{if(document.pictureInPictureElement)document.exitPictureInPicture().catch(()=>{});"
   "return {};})()";

// Chromium's video picture-in-picture window is a frameless views widget that floats on
// every Space. Shaar's own windows and Chromium's bubbles do not combine these traits.
static BOOL ARCIsPictureInPictureVideoWindow(NSWindow *window) {
  return [NSStringFromClass(window.class) hasPrefix:@"NativeWidgetMac"] && window.isVisible
    && window.level == NSFloatingWindowLevel
    && (window.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces) != 0;
}

static NSString *ARCPictureInPictureCommandName(ARCPictureInPictureCommand command) {
  switch (command) {
    case ARCPictureInPictureCommandPlay: return @"play";
    case ARCPictureInPictureCommandPause: return @"pause";
    case ARCPictureInPictureCommandSkip: return @"skip";
  }
  return nil;
}

@implementation ARCShaarRuntime (PictureInPicture)

- (void)enterPictureInPictureInTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) { completion(NO); return; }
  [self shaarSubmit:SHAAR_OP_MEDIA_ENTER_PIP profileID:profileID tabID:tabID
           payload:@{@"schemaVersion": @1}
        completion:^(NSDictionary *result, NSError *error) { completion(error == nil); }];
}

- (void)exitPictureInPictureInTabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) return;
  [self shaarSubmit:SHAAR_OP_MEDIA_EXIT_PIP profileID:profileID tabID:tabID
           payload:@{@"schemaVersion": @1} completion:nil];
}

- (BOOL)engineHandlesAutoPictureInPictureForTabID:(NSString *)tabID {
  return NO;
}

- (void)setAutoPictureInPictureAllowed:(BOOL)allowed tabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID) return;
  [self shaarSubmit:SHAAR_OP_MEDIA_SET_AUTO_PIP profileID:profileID tabID:tabID
           payload:@{@"schemaVersion": @1, @"allowed": @(allowed)} completion:nil];
}

- (NSWindow *)pictureInPictureVideoWindowForTabID:(NSString *)tabID {
  NSWindow *native = [self shaarPictureInPictureWindowForTabID:tabID];
  if (native) return native;
  NSDictionary *state = [self mediaSessionStateForTabID:tabID];
  if (!state[@"pictureInPicture"]) return nil;
  for (NSWindow *window in NSApp.windows)
    if (ARCIsPictureInPictureVideoWindow(window)) return window;
  return nil;
}

- (BOOL)sendPictureInPictureCommand:(ARCPictureInPictureCommand)command seconds:(double)seconds
                              tabID:(NSString *)tabID {
  NSString *profileID = [self shaarProfileIDForTabID:tabID];
  if (!profileID || ![self pictureInPictureVideoWindowForTabID:tabID]) return NO;
  shaar_media_command native = SHAAR_MEDIA_PIP_PLAY;
  switch (command) {
    case ARCPictureInPictureCommandPlay: native = SHAAR_MEDIA_PIP_PLAY; break;
    case ARCPictureInPictureCommandPause: native = SHAAR_MEDIA_PIP_PAUSE; break;
    case ARCPictureInPictureCommandSkip: native = SHAAR_MEDIA_PIP_SKIP; break;
  }
  NSMutableDictionary *payload = [@{@"schemaVersion": @1, @"command": @(native)} mutableCopy];
  if (command == ARCPictureInPictureCommandSkip) {
    if (!std::isfinite(seconds) || seconds == 0 || std::abs(seconds) > 86400) return NO;
    payload[@"value"] = @(seconds);
  }
  return [self shaarSubmit:SHAAR_OP_MEDIA_CONTROL profileID:profileID tabID:tabID
                  payload:payload completion:nil];
}

@end
