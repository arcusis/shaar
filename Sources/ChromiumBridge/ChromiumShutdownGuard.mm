// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumShutdownGuard.h"
#import <AppKit/AppKit.h>
#include <atomic>
#include <memory>
#include <stdio.h>
#include <sysexits.h>
#include <unistd.h>

// Chromium normally leaves its event loop well within the grace period once browsers are closed.
static const int64_t ARCEventLoopGraceSeconds = 5;
// Shutdown after the loop flushes profiles and joins threads; past this it is not progressing.
static const int64_t ARCExitDeadlineSeconds = 30;

static void ARCWakeEventLoop(void) {
  [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                                 modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                       subtype:0 data1:0 data2:0]
           atStart:NO];
}

@implementation ARCEngineShutdownGuard {
  id _observer;
  BOOL _armed;
  std::shared_ptr<std::atomic<bool>> _returned;
}

- (instancetype)init {
  if (!(self = [super init])) return nil;
  _returned = std::make_shared<std::atomic<bool>>(false);
  __weak ARCEngineShutdownGuard *weakSelf = self;
  _observer = [NSNotificationCenter.defaultCenter
      addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
              usingBlock:^(NSNotification *note) { [weakSelf arm]; }];
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:_observer];
}

- (void)engineReturned {
  _returned->store(true);
}

- (void)arm {
  if (_armed) return;
  _armed = YES;
  __weak ARCEngineShutdownGuard *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ARCEventLoopGraceSeconds * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{ [weakSelf stopEventLoop]; });
  // A blocked main thread cannot run the step above, so the deadline runs on its own queue.
  std::shared_ptr<std::atomic<bool>> returned = _returned;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ARCExitDeadlineSeconds * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    if (returned->load()) return;
    fputs("Chromium did not finish shutting down after Quit; exiting.\n", stderr);
    _exit(EX_SOFTWARE);
  });
}

- (void)stopEventLoop {
  if (_returned->load() || !NSApp.isRunning) return;
  _stoppedEventLoop = YES;
  [NSApp stop:nil];
  ARCWakeEventLoop();
}

@end
