// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Page message the media script posts with one frame's Media Session state, or `null`.
FOUNDATION_EXPORT NSString *const ARCMediaSessionMessage;
/// Host message that asks one frame's media script to perform a Media Session action.
FOUNDATION_EXPORT NSString *const ARCMediaActionMessage;
/// Host message that allows or withholds the page's `enterpictureinpicture` handler.
FOUNDATION_EXPORT NSString *const ARCAutoPictureInPictureMessage;

/// Main-world page script. It runs before page code in every frame, records the page's
/// Media Session action handlers and reports playback state, metadata and supported actions.
FOUNDATION_EXPORT NSString *ARCMediaSessionPageScript(void);
/// Joins page scripts that each take `post` and return a message receiver into one script.
FOUNDATION_EXPORT NSString *ARCComposedPageScript(NSArray<NSString *> *scripts);

/// Reduces untrusted per-frame Media Session reports to one validated state per tab.
@interface ARCMediaSessionTracker : NSObject
/// Records one frame's report. Returns YES when the tab's reduced state changed.
- (BOOL)receiveJSON:(NSString *)json frameID:(NSString *)frameID tabID:(NSString *)tabID;
- (nullable NSDictionary<NSString *, id> *)stateForTabID:(NSString *)tabID;
/// The frame whose state the tab reports; actions are sent to it.
- (nullable NSString *)frameIDForTabID:(NSString *)tabID;
/// Every frame that reported media for the tab, oldest report first.
- (NSArray<NSString *> *)frameIDsForTabID:(NSString *)tabID;
/// Drops every frame of the tab. Returns YES when the tab had a state.
- (BOOL)forgetTabID:(NSString *)tabID;
@end

NS_ASSUME_NONNULL_END
