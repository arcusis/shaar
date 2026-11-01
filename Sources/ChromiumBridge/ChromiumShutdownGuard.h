// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Ends the process once Chromium has committed to exit.
///
/// Chromium posts NSApplicationWillTerminateNotification after every browser has closed, then
/// stops the AppKit event loop when idle. That stop can be lost, leaving a windowless process
/// idling in -[NSApplication run] with nothing left to wake it. The guard repeats the stop after
/// a grace period and, if Chromium still has not returned from its main function, exits.
@interface ARCEngineShutdownGuard : NSObject
/// Whether the guard had to stop the event loop itself.
@property(readonly) BOOL stoppedEventLoop;
/// Call when Chromium's main function returns; cancels both pending steps.
- (void)engineReturned;
@end

NS_ASSUME_NONNULL_END
