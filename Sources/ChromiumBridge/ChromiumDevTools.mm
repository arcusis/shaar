// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "ChromiumRuntimeInternal.h"
#import <QuartzCore/QuartzCore.h>

@implementation ARCDevToolsPageView {
  __weak ArdiaCoreTab *_tab;
  NSView *_page;
  NSView *_devTools;
}

- (instancetype)initWithTab:(ArdiaCoreTab *)tab {
  if (!(self = [super initWithFrame:NSZeroRect])) return nil;
  _tab = tab;
  _page = tab.view;
  self.wantsLayer = YES;
  self.layer.masksToBounds = YES;
  [_page removeFromSuperview];
  _page.translatesAutoresizingMaskIntoConstraints = YES;
  _page.autoresizingMask = NSViewNotSizable;
  [self addSubview:_page];
  _page.hidden = self.hidden;
  [self refreshDevTools];
  return self;
}

- (BOOL)isFlipped { return YES; }

- (void)refreshDevTools {
  ArdiaCoreTab *tab = _tab;
  NSView *next = tab && !tab.closed ? tab.devToolsView : nil;
  [self setDevToolsView:next];
}

- (void)setDevToolsView:(NSView *)next {
  BOOL opened = next && next != _devTools;
  if (next != _devTools) {
    if (_devTools.superview == self) [_devTools removeFromSuperview];
    _devTools = next;
  }
  if (_devTools && _devTools.superview != self) {
    [_devTools removeFromSuperview];
    _devTools.translatesAutoresizingMaskIntoConstraints = YES;
    _devTools.autoresizingMask = NSViewNotSizable;
    // The frontend spans the whole card, including its inspected-page placeholder.
    // The real page must cover that placeholder and receive input above it.
    if (_page.superview == self) [self addSubview:_devTools positioned:NSWindowBelow relativeTo:_page];
    else [self addSubview:_devTools];
  }
  if (_page.superview == self) _page.hidden = self.hidden;
  _devTools.hidden = self.hidden;
  [self layoutPage];
  // Never activate a window. A newly opened inspector may take focus only within its
  // already visible, key window; offscreen probes never change desktop focus.
  if (opened && self.window.isVisible && self.window.isKeyWindow)
    [self.window makeFirstResponder:_devTools];
}

- (void)layoutPage {
  ArdiaCoreTab *tab = _tab;
  if (!tab || tab.closed) return;
  NSRect page = self.bounds, tools = NSZeroRect;
  if (_devTools) [tab devToolsLayoutForSize:self.bounds.size devTools:&tools page:&page];
  if (_page.superview == self) _page.frame = page;
  if (_devTools.superview == self) _devTools.frame = tools;
}

- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self layoutPage];
}

- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  // Chromium listens to its own native view's visibility. Hiding only this wrapper
  // leaves a selected page occluded and can stall video loading or playback.
  if (_page.superview == self) _page.hidden = hidden;
  if (_devTools.superview == self) _devTools.hidden = hidden;
}

- (void)layout {
  [super layout];
  [self layoutPage];
}

- (void)invalidate {
  if (_page.superview == self) [_page removeFromSuperview];
  if (_devTools.superview == self) [_devTools removeFromSuperview];
  _page = nil;
  _devTools = nil;
  _tab = nil;
}
@end

@implementation ARCChromiumRuntime (DevTools)
- (NSView *)devToolsViewForTabID:(NSString *)tabID {
  return [self liveTabForID:tabID].devToolsView;
}

- (BOOL)showDevToolsForTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab) return NO;
  [tab showDevTools];
  return YES;
}

- (BOOL)closeDevToolsForTabID:(NSString *)tabID {
  ArdiaCoreTab *tab = [self liveTabForID:tabID];
  if (!tab) return NO;
  [tab closeDevTools];
  return YES;
}

- (void)window:(ArdiaCoreWindow *)window devToolsDidChangeForTab:(ArdiaCoreTab *)tab view:(NSView *)view {
  NSString *identity = [self identityForTab:tab];
  if (!identity) return;
  ARCNativeWindowState *state = [self stateForTabID:identity];
  if (state.native != window || [self liveTabForID:identity] != tab) return;
  [_pageCards[identity] setDevToolsView:view];
  // The frontend initializes its own emulation settings. Let the owning Swift model
  // reapply active Shaar simulations when this inspector opens or closes.
  [self publish:tab];
}
@end
