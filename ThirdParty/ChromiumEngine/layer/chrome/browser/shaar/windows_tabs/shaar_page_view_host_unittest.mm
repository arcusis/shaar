// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <AppKit/AppKit.h>

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"
#include "chrome/browser/shaar/public/shaar_engine.h"
#include "testing/gtest/include/gtest/gtest.h"

@interface ShaarFocusProbeWindow : NSWindow
@property(nonatomic, strong) NSResponder* acceptedResponder;
@end

@implementation ShaarFocusProbeWindow
- (BOOL)isKeyWindow { return YES; }
- (BOOL)makeFirstResponder:(NSResponder*)responder {
  self.acceptedResponder = responder;
  return YES;
}
@end

namespace shaar::windows_tabs {
namespace {

TEST(ShaarPageViewHostTest, ReplacingSelectionDetachesOldViewAndResizesNewView) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* first = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* second = [[NSView alloc] initWithFrame:NSZeroRect];

  EXPECT_TRUE(host.Attach(first));
  EXPECT_EQ(first.superview, host.view());
  EXPECT_TRUE(host.Attach(second));
  EXPECT_EQ(first.superview, nil);
  EXPECT_EQ(second.superview, host.view());

  host.Resize(NSMakeSize(500, 300));
  EXPECT_TRUE(NSEqualRects(second.frame, NSMakeRect(0, 0, 500, 300)));
  EXPECT_FALSE(host.Detach(first));
  EXPECT_TRUE(host.Detach(second));
  EXPECT_EQ(second.superview, nil);
}

TEST(ShaarPageViewHostTest, WindowStartsHiddenAndRejectsForeignFocus) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* tab = [[NSView alloc] initWithFrame:NSZeroRect];

  EXPECT_FALSE(host.window().isVisible);
  EXPECT_FALSE(host.Focus(tab));
  EXPECT_TRUE(host.Attach(tab));
  EXPECT_FALSE(host.Focus([[NSView alloc] initWithFrame:NSZeroRect]));
}

TEST(ShaarPageViewHostTest, FocusUsesTheAttachedViewsKeyWindow) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* tab = [[NSView alloc] initWithFrame:NSZeroRect];
  ASSERT_TRUE(host.Attach(tab));
  ShaarFocusProbeWindow* target = [[ShaarFocusProbeWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 800, 600)
              styleMask:NSWindowStyleMaskBorderless
                backing:NSBackingStoreBuffered
                  defer:YES];
  target.contentView = tab;
  EXPECT_FALSE(target.isVisible);
  EXPECT_TRUE(host.Focus(tab));
  EXPECT_EQ(target.acceptedResponder, tab);
  host.Detach(tab);
  [target close];
}

TEST(ShaarPageViewHostTest, MovingViewLeavesPreviousHostEmpty) {
  PageViewHost source(NSMakeRect(0, 0, 800, 600));
  PageViewHost destination(NSMakeRect(0, 0, 400, 300));
  NSView* tab = [[NSView alloc] initWithFrame:NSZeroRect];
  ASSERT_TRUE(source.Attach(tab));

  EXPECT_TRUE(destination.Attach(tab));
  EXPECT_EQ(source.selected_view(), nil);
  EXPECT_EQ(destination.selected_view(), tab);
  EXPECT_EQ(tab.superview, destination.view());
}

TEST(ShaarPageViewHostTest, ClosingHiddenWindowSurvivesAutoreleaseDrain) {
  @autoreleasepool {
    PageViewHost host(NSMakeRect(0, 0, 800, 600));
    EXPECT_FALSE(host.window().isVisible);
  }
}

TEST(ShaarPageViewHostTest, PublicABIRejectsUnregisteredHandles) {
  auto* engine = reinterpret_cast<shaar_engine*>(1);
  auto* window = reinterpret_cast<shaar_window*>(2);
  auto* tab = reinterpret_cast<shaar_tab*>(3);
  shaar_error error = {};
  error.size = sizeof(error);

  EXPECT_EQ(shaar_window_host_view(window), nullptr);
  EXPECT_EQ(shaar_tab_host_view(tab), nullptr);
  shaar_scope scope{sizeof(shaar_scope), reinterpret_cast<shaar_profile *>(4),
                    nullptr};
  EXPECT_EQ(shaar_devtools_frontend_view(engine, scope, window, tab), nullptr);
  EXPECT_EQ(shaar_tab_view_attach(engine, window, tab, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(error.code, SHAAR_NOT_FOUND);
  shaar_tab_probe_state state = {};
  state.size = sizeof(state);
  state.live_web_contents = 1;
  state.selected_native_tab = 1;
  state.displayed_native_web_contents = 1;
  state.context_is_private = 1;
  state.scope_owns_tab = 1;
  EXPECT_EQ(shaar_tab_get_probe_state(engine, scope, window, tab, &state, &error),
            SHAAR_NOT_FOUND);
  EXPECT_EQ(error.code, SHAAR_NOT_FOUND);
  EXPECT_EQ(state.live_web_contents, 0);
  EXPECT_EQ(state.selected_native_tab, 0);
  EXPECT_EQ(state.displayed_native_web_contents, 0);
  EXPECT_EQ(state.context_is_private, 0);
  EXPECT_EQ(state.scope_owns_tab, 0);
  shaar_scope ambiguous{sizeof(shaar_scope),
                        reinterpret_cast<shaar_profile *>(4),
                        reinterpret_cast<shaar_private_session *>(5)};
  EXPECT_EQ(shaar_tab_get_probe_state(engine, ambiguous, window, tab, &state,
                                     &error), SHAAR_INVALID_ARGUMENT);
  state.size = sizeof(state) - 1;
  EXPECT_EQ(shaar_tab_get_probe_state(engine, scope, window, tab, &state, &error),
            SHAAR_INVALID_ARGUMENT);
  EXPECT_EQ(error.code, SHAAR_INVALID_ARGUMENT);
}

}  // namespace
}  // namespace shaar::windows_tabs
