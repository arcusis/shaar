// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_PAGE_VIEW_HOST_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_PAGE_VIEW_HOST_H_

#import <AppKit/AppKit.h>

#include "base/memory/weak_ptr.h"

namespace content {
class WebContents;
}

namespace shaar::windows_tabs {

// UI-thread AppKit owner. Chromium owns the tab view; this class only borrows it
// while selected. The window and its content view live until the ABI window closes.
class PageViewHost final {
 public:
  explicit PageViewHost(NSRect frame, NSWindow* window = nil);
  ~PageViewHost();
  PageViewHost(const PageViewHost&) = delete;
  PageViewHost& operator=(const PageViewHost&) = delete;

  NSWindow* window() const { return window_; }
  NSView* view() const { return view_; }
  NSView* selected_view() const { return selected_view_; }
  bool Attach(NSView* tab_view);
  bool Detach(NSView* tab_view);
  void Resize(NSSize size);
  bool Focus(NSView* tab_view);
  void SetSelectedWebContents(content::WebContents* contents);
  void RefreshVisibility();

 private:
  __strong NSWindow* window_ = nil;
  __strong NSView* view_ = nil;
  __strong NSView* selected_view_ = nil;
  base::WeakPtr<content::WebContents> selected_contents_;
  __strong id occlusion_observer_ = nil;
  __strong id miniaturize_observer_ = nil;
  __strong id deminiaturize_observer_ = nil;
};

}  // namespace shaar::windows_tabs

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_PAGE_VIEW_HOST_H_
