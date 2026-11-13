// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <AppKit/AppKit.h>

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"
#include "chrome/browser/shaar/windows_tabs/shaar_page_view_binding.h"
#include "chrome/browser/shaar/public/shaar_engine.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_renderer_host.h"
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

@interface ShaarVisibilityProbeWindow : NSWindow
@property(nonatomic) BOOL probeVisible;
@property(nonatomic) BOOL probeMiniaturized;
@property(nonatomic) NSWindowOcclusionState probeOcclusion;
@end

@implementation ShaarVisibilityProbeWindow
- (BOOL)isVisible { return self.probeVisible; }
- (BOOL)isMiniaturized { return self.probeMiniaturized; }
- (NSWindowOcclusionState)occlusionState { return self.probeOcclusion; }
@end

namespace shaar::windows_tabs {
namespace {

class ShaarTabVisibilityTest : public content::RenderViewHostTestHarness {};

TEST_F(ShaarTabVisibilityTest, SelectionShowsRendererAndDeselectionHidesIt) {
  web_contents()->WasHidden();
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::HIDDEN);
  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::VISIBLE);
  ShowSelectedWebContents(web_contents(), nullptr);
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::HIDDEN);
}

TEST_F(ShaarTabVisibilityTest, FallbackSelectionTracksOwningWindowVisibility) {
  ShaarVisibilityProbeWindow* window = [[ShaarVisibilityProbeWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 800, 600)
              styleMask:NSWindowStyleMaskBorderless
                backing:NSBackingStoreBuffered
                  defer:YES];
  [window.contentView addSubview:web_contents()->GetNativeView().GetNativeNSView()];
  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::HIDDEN);
  window.probeVisible = YES;
  window.probeOcclusion = NSWindowOcclusionStateVisible;
  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::VISIBLE);
  window.probeOcclusion = 0;
  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::OCCLUDED);
  window.probeMiniaturized = YES;
  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::HIDDEN);
}

TEST_F(ShaarTabVisibilityTest, FallbackSelectionDeliversOnlyRealVisibilityChanges) {
  web_contents()->WasHidden();
  ShaarVisibilityProbeWindow* window = [[ShaarVisibilityProbeWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 800, 600)
              styleMask:NSWindowStyleMaskBorderless
                backing:NSBackingStoreBuffered
                  defer:YES];
  [window.contentView addSubview:web_contents()->GetNativeView().GetNativeNSView()];
  ASSERT_TRUE(content::ExecJs(
      web_contents(),
      "window.visibilityChangeCount = 0;"
      "document.addEventListener('visibilitychange', () => ++window.visibilityChangeCount);"));

  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(content::EvalJs(web_contents(), "window.visibilityChangeCount").ExtractInt(), 0);

  window.probeVisible = YES;
  window.probeOcclusion = NSWindowOcclusionStateVisible;
  ShowSelectedWebContents(nullptr, web_contents());
  EXPECT_EQ(content::EvalJs(web_contents(), "window.visibilityChangeCount").ExtractInt(), 1);
}

TEST_F(ShaarTabVisibilityTest, HostTracksWindowOcclusionWithoutOrderingIt) {
  web_contents()->WasHidden();
  ShaarVisibilityProbeWindow* window = [[ShaarVisibilityProbeWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 800, 600)
              styleMask:NSWindowStyleMaskBorderless
                backing:NSBackingStoreBuffered
                  defer:YES];
  PageViewHost host(NSMakeRect(0, 0, 800, 600), window);
  host.SetSelectedWebContents(web_contents());
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::HIDDEN);
  ASSERT_TRUE(content::ExecJs(
      web_contents(),
      "window.visibilityChangeCount = 0;"
      "document.addEventListener('visibilitychange', () => ++window.visibilityChangeCount);"));
  window.probeVisible = YES;
  window.probeOcclusion = NSWindowOcclusionStateVisible;
  host.RefreshVisibility();
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::VISIBLE);
  EXPECT_EQ(content::EvalJs(web_contents(), "window.visibilityChangeCount").ExtractInt(), 1);
  window.probeOcclusion = 0;
  host.RefreshVisibility();
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::OCCLUDED);
  window.probeMiniaturized = YES;
  host.RefreshVisibility();
  EXPECT_EQ(web_contents()->GetVisibility(), content::Visibility::HIDDEN);
  EXPECT_EQ(content::EvalJs(web_contents(), "window.visibilityChangeCount").ExtractInt(), 2);
}

TEST(ShaarPageViewHostTest, DockedFrontendResizesAndClosesWithoutClosingHost) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* page = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* frontend = [[NSView alloc] initWithFrame:NSZeroRect];
  ASSERT_TRUE(host.Attach(page));
  host.SetDevToolsView(frontend);
  EXPECT_EQ(page.window, host.window());
  EXPECT_EQ(frontend.window, host.window());
  EXPECT_EQ(page.frame.size.width, 480);
  EXPECT_EQ(frontend.frame.origin.x, 0);
  EXPECT_EQ(frontend.frame.size.width, 800);
  EXPECT_GT([host.view().subviews indexOfObject:page],
            [host.view().subviews indexOfObject:frontend]);
  EXPECT_FALSE(host.window().isVisible);
  host.SetDevToolsPageBounds(gfx::Rect(0, 0, 530, 600));
  EXPECT_EQ(page.frame.size.width, 530);
  shaar_devtools_geometry geometry = {.size = sizeof(geometry)};
  ASSERT_TRUE(host.GetDevToolsGeometry(&geometry));
  EXPECT_DOUBLE_EQ(geometry.inspected_page_right,
                   geometry.frontend_placeholder_right);
  EXPECT_DOUBLE_EQ(geometry.frontend_width, geometry.container_width);
  host.Resize(NSMakeSize(1000, 700));
  EXPECT_EQ(frontend.frame.size.width, 1000);
  EXPECT_EQ(frontend.frame.size.height, 700);
  // DevTools sends new inspected-page bounds after a window resize and after
  // its divider is dragged. Both must move the page with its placeholder.
  host.SetDevToolsPageBounds(gfx::Rect(0, 0, 620, 700));
  EXPECT_EQ(page.frame.size.width, 620);
  host.SetDevToolsPageBounds(gfx::Rect(0, 0, 410, 700));
  EXPECT_EQ(page.frame.size.width, 410);
  ASSERT_TRUE(host.GetDevToolsGeometry(&geometry));
  EXPECT_DOUBLE_EQ(geometry.inspected_page_right,
                   geometry.frontend_placeholder_right);
  host.SetDevToolsView(nil);
  EXPECT_EQ(frontend.superview, nil);
  EXPECT_EQ(page.frame.size.width, 1000);
  EXPECT_EQ(page.window, host.window());
  EXPECT_FALSE(host.window().isVisible);
}

TEST(ShaarPageViewHostTest, DockFollowsBorrowedPageContainerAndSurvivesAppLayout) {
  PageViewHost host(NSMakeRect(0, 0, 1000, 700));
  NSView* page = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* frontend = [[NSView alloc] initWithFrame:NSZeroRect];
  NSView* app = [[NSView alloc] initWithFrame:NSMakeRect(200, 80, 800, 620)];
  [host.view() addSubview:app];
  ASSERT_TRUE(host.Attach(page));
  [app addSubview:page];
  host.SetDevToolsView(frontend);
  EXPECT_EQ(frontend.superview, app);
  EXPECT_EQ(page.frame.size.width, 480);
  EXPECT_EQ(frontend.frame.origin.x, 0);
  EXPECT_EQ(frontend.frame.size.width, 800);
  page.frame = app.bounds;  // Simulate ChromiumPage's SwiftUI layout callback.
  EXPECT_EQ(page.frame.size.width, 480);
  EXPECT_EQ(frontend.frame.size.width, 800);
  app.frame = NSMakeRect(200, 80, 600, 500);
  page.frame = app.bounds;
  EXPECT_EQ(page.frame.size.width, 360);
  EXPECT_EQ(frontend.frame.size.width, 600);
  host.SetDevToolsView(nil);
  EXPECT_EQ(page.frame.size.width, 600);
  EXPECT_EQ(frontend.superview, nil);
  EXPECT_FALSE(host.window().isVisible);
}

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
  EXPECT_EQ(tab.window, host.window());
  EXPECT_FALSE(host.window().isVisible);
  host.Resize(NSMakeSize(640, 480));
  EXPECT_FALSE(host.window().isVisible);
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
  target.releasedWhenClosed = NO;
  target.contentView = tab;
  EXPECT_FALSE(target.isVisible);
  EXPECT_TRUE(host.Focus(tab));
  EXPECT_EQ(target.acceptedResponder, tab);
  host.Detach(tab);
  [target close];
}

TEST_F(ShaarTabVisibilityTest, FocusForwardsToSelectedWebContents) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* tab = web_contents()->GetNativeView().GetNativeNSView();
  ASSERT_TRUE(host.Attach(tab));
  host.SetSelectedWebContents(web_contents());
  ShaarFocusProbeWindow* target = [[ShaarFocusProbeWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 800, 600)
              styleMask:NSWindowStyleMaskBorderless
                backing:NSBackingStoreBuffered
                  defer:YES];
  target.releasedWhenClosed = NO;
  target.contentView = tab;
  web_contents()->WasShown();
  ASSERT_TRUE(content::ExecJs(
      web_contents(),
      "window.pageFocusCount = 0;"
      "window.addEventListener('focus', () => ++window.pageFocusCount);"));

  ASSERT_TRUE(host.Focus(tab));
  EXPECT_EQ(target.acceptedResponder, tab);
  EXPECT_EQ(content::EvalJs(web_contents(), "window.pageFocusCount").ExtractInt(), 1);
  host.Detach(tab);
  [target close];
}

TEST(ShaarPageViewHostTest, ReattachesSelectionAfterItsPreviousPresenterDetaches) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* tab = [[NSView alloc] initWithFrame:NSZeroRect];
  ASSERT_TRUE(host.Attach(tab));
  [tab removeFromSuperview];
  ASSERT_EQ(tab.window, nil);
  ASSERT_TRUE(host.Attach(tab));
  EXPECT_EQ(tab.window, host.window());
  EXPECT_EQ(tab.superview, host.view());
}

TEST(ShaarPageViewHostTest, AttachClearsChromiumDetachHiddenFlagWithoutShowingWindow) {
  PageViewHost host(NSMakeRect(0, 0, 800, 600));
  NSView* tab = [[NSView alloc] initWithFrame:NSZeroRect];
  // WebContentsViewMac::ViewsHostableDetach leaves the borrowed NSView hidden.
  tab.hidden = YES;
  ASSERT_TRUE(host.Attach(tab));
  EXPECT_FALSE(tab.hidden);
  EXPECT_FALSE(tab.isHiddenOrHasHiddenAncestor);
  EXPECT_FALSE(host.window().isVisible);
  // A repeated BrowserView presentation/detach must also be repaired even
  // when the native view is already in the right Shaar window.
  tab.hidden = YES;
  ASSERT_TRUE(host.Attach(tab));
  EXPECT_FALSE(tab.hidden);
  EXPECT_FALSE(host.window().isVisible);
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
