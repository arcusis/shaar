// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Page message the media script posts with one frame's Media Session state, or `null`.
FOUNDATION_EXPORT NSString *const ARCMediaSessionMessage;
/// Host message that asks one frame's media script to perform a Media Session action.
FOUNDATION_EXPORT NSString *const ARCMediaActionMessage;
/// Host message that sets the active media element's volume.
FOUNDATION_EXPORT NSString *const ARCMediaVolumeMessage;
/// Host message that allows or withholds the page's `enterpictureinpicture` handler.
FOUNDATION_EXPORT NSString *const ARCAutoPictureInPictureMessage;
/// Host message that plays, pauses or skips the video in Chromium's picture-in-picture window.
FOUNDATION_EXPORT NSString *const ARCPictureInPictureCommandMessage;

/// Main-world page script. It runs before page code in every frame, records the page's
/// Media Session action handlers and reports playback state, metadata and supported actions.
FOUNDATION_EXPORT NSString *ARCMediaSessionPageScript(void);
/// Joins page scripts that each take `post` and return a message receiver into one script.
FOUNDATION_EXPORT NSString *ARCComposedPageScript(NSArray<NSString *> *scripts);

/// Reduces one versioned native Shaar media state to the app's media model payload.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable ARCShaarMediaPublicState(
  NSDictionary<NSString *, id> *native);

@class ARCShaarRuntime;
@interface ARCShaarRuntime (MediaEvents)
- (void)receiveShaarMediaEventForTabID:(NSString *)tabID payload:(NSDictionary *)payload;
- (void)forgetShaarMediaForTabID:(NSString *)tabID;
@end

NS_ASSUME_NONNULL_END
