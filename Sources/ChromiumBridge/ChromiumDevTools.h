// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <AppKit/AppKit.h>
@class ArdiaCoreTab;

/// Stable page-card content. Chromium owns the inspector's splitter and saved dock settings.
@interface ARCDevToolsPageView : NSView
- (instancetype)initWithTab:(ArdiaCoreTab *)tab;
- (void)refreshDevTools;
- (void)setDevToolsView:(NSView *)view;
- (void)invalidate;
@end
