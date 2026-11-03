// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_NAVIGATION_SHAAR_NAVIGATION_H_
#define CHROME_BROWSER_SHAAR_NAVIGATION_SHAAR_NAVIGATION_H_

#include <string>

#include "content/public/browser/web_contents_observer.h"
#include "chrome/browser/shaar/public/shaar_engine.h"
#include "url/gurl.h"

struct shaar_engine;

namespace content {
class NavigationHandle;
class NavigationController;
class NavigationEntry;
class WebContents;
}  // namespace content

namespace shaar::navigation {

// URL policy shared by address-bar, favorite, and page initiated requests.
// `canonical_url` is populated only on success and never contains credentials.
shaar_error_code ValidateURL(const std::string& input,
                             std::string* canonical_url);

// These operations run on Chromium's UI thread after the caller has checked
// exact profile/session/window/tab ownership. They return boundary errors
// synchronously; accepted actions are acknowledged by the owning dispatcher.
shaar_error_code Navigate(content::WebContents* contents,
                          const std::string& url,
                          bool user_initiated);
shaar_error_code Go(content::NavigationController* controller,
                    bool forward);
shaar_error_code Reload(content::NavigationController* controller,
                        bool bypass_cache);
shaar_error_code Stop(content::WebContents* contents);
std::string PageReadableURL(const GURL& url);

// Own one observer per live tab. The window/tab owner creates and destroys it
// alongside the exact scoped handle, and closes the tab before invalidation.
class NavigationObserver final : public content::WebContentsObserver {
 public:
  NavigationObserver(shaar_engine* engine,
                     content::WebContents* contents,
                     std::string profile_id,
                     std::string session_id,
                     std::string window_id,
                     std::string tab_id);
  ~NavigationObserver() override;

  void EmitInitialState();
  void DidStartNavigation(content::NavigationHandle* handle) override;
  void DidFinishNavigation(content::NavigationHandle* handle) override;
  void DidStopLoading() override;
  void TitleWasSet(content::NavigationEntry* entry) override;
  void WebContentsDestroyed() override;

 private:
  void Emit(const char* phase,
            const std::string& navigation_id,
            bool same_document,
            content::NavigationHandle* handle = nullptr);

  shaar_engine* engine_;
  std::string profile_id_;
  std::string session_id_;
  std::string window_id_;
  std::string tab_id_;
  std::string active_navigation_id_;
  uint64_t generation_ = 0;
  bool destroyed_ = false;
};

}  // namespace shaar::navigation

#endif  // CHROME_BROWSER_SHAAR_NAVIGATION_SHAAR_NAVIGATION_H_
