// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
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

@implementation ARCChromiumRuntime (PictureInPicture)

- (void)enterPictureInPictureInTabID:(NSString *)tabID completion:(void (^)(BOOL))completion {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab) { completion(NO); return; }
  [self evaluateTab:tab script:ARCEnterPictureInPictureScript userGesture:YES completion:^(NSString *json) {
    completion([json containsString:@"\"requested\":true"]);
  }];
}

- (void)exitPictureInPictureInTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (tab) [self evaluateTab:tab script:ARCExitPictureInPictureScript completion:^(NSString *json) {}];
}

- (BOOL)engineHandlesAutoPictureInPictureForTabID:(NSString *)tabID {
  return [self liveTabForID:tabID].autoPictureInPictureIsChromes;
}

- (NSWindow *)pictureInPictureVideoWindowForTabID:(NSString *)tabID {
  if (![_pictureInPictureVideoTabID isEqualToString:tabID] || ![self liveTabForID:tabID]) return nil;
  for (NSWindow *window in NSApp.windows) {
    if (ARCIsPictureInPictureVideoWindow(window)) return window;
  }
  return nil;
}

- (BOOL)sendPictureInPictureCommand:(ARCPictureInPictureCommand)command seconds:(double)seconds
                              tabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  NSString *name = ARCPictureInPictureCommandName(command);
  if (!tab || !name || ![_pictureInPictureVideoTabID isEqualToString:tabID]) return NO;
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{
    @"command": name, @"seconds": @(std::isfinite(seconds) ? seconds : 0),
  } options:0 error:nil];
  if (!data) return NO;
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  // Only the frame whose video is in picture-in-picture acts on the command.
  tab.frozen = NO;
  for (NSString *frameID in [_mediaSessions frameIDsForTabID:tabID]) {
    [tab callFrame:frameID kind:ARCPictureInPictureCommandMessage json:json];
  }
  return YES;
}

- (void)setAutoPictureInPictureAllowed:(BOOL)allowed tabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab) return;
  NSString *json = allowed ? @"{\"allowed\":true}" : @"{\"allowed\":false}";
  [tab callPage:ARCAutoPictureInPictureMessage json:json];
  for (NSString *frameID in [_mediaSessions frameIDsForTabID:tabID]) {
    [tab callFrame:frameID kind:ARCAutoPictureInPictureMessage json:json];
  }
}

@end

@implementation ARCChromiumRuntime (PictureInPictureSupport)

- (void)notePictureInPictureVideoTabID:(NSString *)tabID active:(BOOL)active kind:(id)kind {
  if (active) {
    _pictureInPictureVideoTabID = [kind isEqual:@"video"] ? tabID : nil;
  } else if ([_pictureInPictureVideoTabID isEqualToString:tabID]) {
    _pictureInPictureVideoTabID = nil;
  }
}

@end
