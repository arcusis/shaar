// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"

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
