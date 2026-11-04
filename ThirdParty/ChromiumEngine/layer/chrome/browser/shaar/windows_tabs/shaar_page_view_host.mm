// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"

#include <unordered_map>

namespace shaar::windows_tabs {

namespace {
std::unordered_map<void*, PageViewHost*>& SelectedOwners() {
  static std::unordered_map<void*, PageViewHost*> owners;
  return owners;
}
}  // namespace

PageViewHost::PageViewHost(NSRect frame) {
  window_ = [[NSWindow alloc] initWithContentRect:frame
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
}

PageViewHost::~PageViewHost() {
  if (selected_view_)
    Detach(selected_view_);
  [window_ close];
}

bool PageViewHost::Attach(NSView* tab_view) {
  if (!tab_view || tab_view == view_)
    return false;
  if (selected_view_ == tab_view)
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
  return true;
}

void PageViewHost::Resize(NSSize size) {
  if (size.width < 0 || size.height < 0)
    return;
  [view_ setFrameSize:size];
  if (selected_view_)
    selected_view_.frame = view_.bounds;
}

bool PageViewHost::Focus(NSView* tab_view) {
  if (!tab_view || selected_view_ != tab_view || !window_.isKeyWindow)
    return false;
  return [window_ makeFirstResponder:tab_view];
}

}  // namespace shaar::windows_tabs
