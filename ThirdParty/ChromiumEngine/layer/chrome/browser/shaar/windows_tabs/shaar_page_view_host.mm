// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"

#include <algorithm>
#include <unordered_map>
#include "chrome/browser/devtools/devtools_contents_resizing_strategy.h"
#include "chrome/browser/devtools/devtools_window.h"

#include "content/public/browser/web_contents.h"

@interface ShaarPageHostWindow : NSWindow
@property(nonatomic, readonly) BOOL wasShown;
@end

@implementation ShaarPageHostWindow {
  BOOL _wasShown;
}
- (BOOL)wasShown { return _wasShown; }
- (void)orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWin {
  if (place != NSWindowOut) _wasShown = YES;
  [super orderWindow:place relativeTo:otherWin];
}
@end

namespace shaar::windows_tabs {

namespace {
std::unordered_map<void*, PageViewHost*>& SelectedOwners() {
  static std::unordered_map<void*, PageViewHost*> owners;
  return owners;
}
}  // namespace

bool HasHiddenNativeWindow(content::WebContents* contents) {
  NSView* view = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  return view.window && !view.window.isVisible;
}

void UpdateDockedDevTools(content::WebContents* inspected,
                          content::WebContents* frontend) {
  if (!inspected)
    return;
  NSView* view = inspected->GetNativeView().GetNativeNSView();
  auto it = SelectedOwners().find((__bridge void*)view);
  if (it != SelectedOwners().end()) {
    DevToolsContentsResizingStrategy strategy;
    if (frontend)
      DevToolsWindow::GetInTabWebContents(inspected, &strategy);
    it->second->SetDevToolsContents(frontend);
    it->second->SetDevToolsPageBounds(strategy.bounds());
  }
}

PageViewHost::PageViewHost(NSRect frame, NSWindow* window) {
  window_ = window ?: [[ShaarPageHostWindow alloc] initWithContentRect:frame
                                        styleMask:(NSWindowStyleMaskTitled |
                                                   NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable |
                                                   NSWindowStyleMaskMiniaturizable)
                                          backing:NSBackingStoreBuffered
                                            defer:YES];
  view_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width,
                                                  frame.size.height)];
  window_.contentView = view_;
  window_.releasedWhenClosed = NO;
  window_.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  [window_ orderOut:nil];
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  view_.postsFrameChangedNotifications = YES;
  frame_observer_ = [center addObserverForName:NSViewFrameDidChangeNotification
      object:view_ queue:nil usingBlock:^(NSNotification*) { LayoutPages(); }];
  auto refresh = ^(NSNotification*) { RefreshVisibility(); };
  occlusion_observer_ = [center
      addObserverForName:NSWindowDidChangeOcclusionStateNotification
                 object:window_ queue:nil usingBlock:refresh];
  miniaturize_observer_ = [center
      addObserverForName:NSWindowDidMiniaturizeNotification
                 object:window_ queue:nil usingBlock:refresh];
  deminiaturize_observer_ = [center
      addObserverForName:NSWindowDidDeminiaturizeNotification
                 object:window_ queue:nil usingBlock:refresh];
}

bool PageViewHost::NeverShown() const {
  return [window_ isKindOfClass:ShaarPageHostWindow.class] &&
         ![(ShaarPageHostWindow*)window_ wasShown] && !window_.isVisible;
}

PageViewHost::~PageViewHost() {
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center removeObserver:frame_observer_];
  [center removeObserver:occlusion_observer_];
  [center removeObserver:miniaturize_observer_];
  [center removeObserver:deminiaturize_observer_];
  SetSelectedWebContents(nullptr);
  if (selected_view_)
    Detach(selected_view_);
  [window_ close];
}

bool PageViewHost::Attach(NSView* tab_view) {
  if (!tab_view || tab_view == view_)
    return false;
  // Chromium's ViewsHostableDetach hides the NSView before giving up its
  // compositor. Shaar owns presentation now; clearing this per-view flag does
  // not order the NSWindow in or change hidden-window renderer visibility.
  tab_view.hidden = NO;
  if (selected_view_ == tab_view && tab_view.window == window_)
    return true;
  void* identity = (__bridge void*)tab_view;
  auto prior = SelectedOwners().find(identity);
  if (prior != SelectedOwners().end() && prior->second != this)
    prior->second->Detach(tab_view);
  if (selected_view_)
    Detach(selected_view_);
  [tab_view removeFromSuperview];
  tab_view.frame = view_.bounds;
  tab_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [view_ addSubview:tab_view];
  selected_view_ = tab_view;
  tab_view.postsFrameChangedNotifications = YES;
  page_frame_observer_ = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification object:tab_view
      queue:nil usingBlock:^(NSNotification*) {
        if (devtools_view_)
          LayoutPages();
      }];
  LayoutPages();
  SelectedOwners()[identity] = this;
  return true;
}

bool PageViewHost::Detach(NSView* tab_view) {
  if (!tab_view || selected_view_ != tab_view)
    return false;
  [NSNotificationCenter.defaultCenter removeObserver:page_frame_observer_];
  page_frame_observer_ = nil;
  [tab_view removeFromSuperview];
  SelectedOwners().erase((__bridge void*)tab_view);
  selected_view_ = nil;
  SetSelectedWebContents(nullptr);
  return true;
}

void PageViewHost::SetSelectedWebContents(content::WebContents* contents) {
  content::WebContents* previous = selected_contents_.get();
  if (previous && previous != contents)
    previous->UpdateWebContentsVisibility(content::Visibility::HIDDEN);
  selected_contents_ = contents ? contents->GetWeakPtr()
                                : base::WeakPtr<content::WebContents>();
  DevToolsContentsResizingStrategy strategy;
  content::WebContents* frontend = contents
      ? DevToolsWindow::GetInTabWebContents(contents, &strategy) : nullptr;
  SetDevToolsContents(frontend);
  SetDevToolsPageBounds(strategy.bounds());
  RefreshVisibility();
}

void PageViewHost::RefreshVisibility() {
  content::WebContents* contents = selected_contents_.get();
  if (!contents)
    return;
  content::Visibility visibility = content::Visibility::HIDDEN;
  if (window_.isVisible && !window_.isMiniaturized) {
    visibility = (window_.occlusionState & NSWindowOcclusionStateVisible)
                     ? content::Visibility::VISIBLE
                     : content::Visibility::OCCLUDED;
  }
  contents->UpdateWebContentsVisibility(visibility);
  if (devtools_contents_)
    devtools_contents_->UpdateWebContentsVisibility(visibility);
}

void PageViewHost::Resize(NSSize size) {
  if (size.width < 0 || size.height < 0)
    return;
  [view_ setFrameSize:size];
  LayoutPages();
}

void PageViewHost::SetDevToolsContents(content::WebContents* frontend) {
  if (devtools_contents_ && devtools_contents_.get() != frontend)
    devtools_contents_->UpdateWebContentsVisibility(content::Visibility::HIDDEN);
  devtools_contents_ = frontend ? frontend->GetWeakPtr() : base::WeakPtr<content::WebContents>();
  SetDevToolsView(frontend ? frontend->GetNativeView().GetNativeNSView() : nil);
  RefreshVisibility();
}

void PageViewHost::SetDevToolsView(NSView* frontend) {
  if (devtools_view_ != frontend) {
    [devtools_view_ removeFromSuperview];
    devtools_view_ = frontend;
  }
  if (frontend) {
    if (frontend.superview != view_) {
      [frontend removeFromSuperview];
      [view_ addSubview:frontend];
    }
    frontend.hidden = NO;
    frontend.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  } else {
    devtools_page_bounds_ = gfx::Rect();
  }
  LayoutPages();
}

void PageViewHost::SetDevToolsPageBounds(const gfx::Rect& bounds) {
  devtools_page_bounds_ = devtools_view_ ? bounds : gfx::Rect();
  LayoutPages();
}

bool PageViewHost::GetDevToolsGeometry(shaar_devtools_geometry* out) const {
  if (!out || !selected_view_ || !devtools_view_ ||
      devtools_page_bounds_.IsEmpty())
    return false;
  NSView* container = selected_view_.superview;
  if (!container || devtools_view_.superview != container)
    return false;
  out->container_width = NSWidth(container.bounds);
  out->inspected_page_right = NSMaxX(selected_view_.frame);
  out->frontend_placeholder_right = devtools_page_bounds_.right();
  out->frontend_width = NSWidth(devtools_view_.frame);
  return true;
}

void PageViewHost::LayoutPages() {
  if (laying_out_pages_)
    return;
  laying_out_pages_ = true;
  // SwiftUI can borrow the page into its content container below the toolbar.
  // Dock beside that page, not over the outer window/sidebar. Its layout may
  // reset the borrowed page frame; the frame observer reapplies this split.
  NSView* container = selected_view_.superview ?: view_;
  if (devtools_view_ && devtools_view_.superview != container) {
    [devtools_view_ removeFromSuperview];
    [container addSubview:devtools_view_];
  }
  NSRect bounds = container.bounds;
  NSRect page_frame = bounds;
  if (devtools_view_) {
    // Chromium's DevTools frontend owns the splitter and paints a placeholder
    // for the inspected page. It must see the full container. Cropping the
    // frontend to a side strip leaves its placeholder as an empty dark gap.
    devtools_view_.frame = bounds;
    if (devtools_page_bounds_.IsEmpty()) {
      page_frame.size.width = bounds.size.width * 0.6;
    } else {
      const CGFloat width = NSWidth(bounds);
      const CGFloat height = NSHeight(bounds);
      const CGFloat left = std::clamp(
          static_cast<CGFloat>(devtools_page_bounds_.x()), 0.0, width);
      const CGFloat right = std::clamp(
          static_cast<CGFloat>(devtools_page_bounds_.right()), left, width);
      const CGFloat top = std::clamp(
          static_cast<CGFloat>(devtools_page_bounds_.y()), 0.0, height);
      const CGFloat bottom = std::clamp(
          static_cast<CGFloat>(devtools_page_bounds_.bottom()), top, height);
      page_frame = NSMakeRect(NSMinX(bounds) + left,
                              NSMinY(bounds) + height - bottom,
                              right - left, bottom - top);
    }
    // The inspected page covers the frontend placeholder and receives input.
    if (selected_view_) {
      NSUInteger page_index = [container.subviews indexOfObject:selected_view_];
      NSUInteger frontend_index =
          [container.subviews indexOfObject:devtools_view_];
      if (page_index != NSNotFound && frontend_index != NSNotFound &&
          page_index < frontend_index)
        [container addSubview:selected_view_ positioned:NSWindowAbove
                                            relativeTo:devtools_view_];
    }
  }
  if (selected_view_)
    selected_view_.frame = page_frame;
  laying_out_pages_ = false;
}

bool PageViewHost::Focus(NSView* tab_view) {
  NSWindow* target = tab_view.window;
  if (!tab_view || selected_view_ != tab_view || !target.isKeyWindow)
    return false;
  if (![target makeFirstResponder:tab_view])
    return false;
  if (content::WebContents* contents = selected_contents_.get())
    contents->Focus();
  return true;
}

}  // namespace shaar::windows_tabs
