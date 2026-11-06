// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"

#include <unordered_map>

#include "content/public/browser/web_contents.h"

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

PageViewHost::PageViewHost(NSRect frame, NSWindow* window) {
  window_ = window ?: [[NSWindow alloc] initWithContentRect:frame
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

PageViewHost::~PageViewHost() {
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
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
  SelectedOwners()[identity] = this;
  return true;
}

bool PageViewHost::Detach(NSView* tab_view) {
  if (!tab_view || selected_view_ != tab_view)
    return false;
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
}

void PageViewHost::Resize(NSSize size) {
  if (size.width < 0 || size.height < 0)
    return;
  [view_ setFrameSize:size];
  if (selected_view_)
    selected_view_.frame = view_.bounds;
}

bool PageViewHost::Focus(NSView* tab_view) {
  NSWindow* target = tab_view.window;
  if (!tab_view || selected_view_ != tab_view || !target.isKeyWindow)
    return false;
  return [target makeFirstResponder:tab_view];
}

}  // namespace shaar::windows_tabs
