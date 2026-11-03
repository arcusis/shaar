// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_

#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "chrome/browser/shaar/engine/shaar_engine_context.h"

class TabStripModel;
class Browser;
namespace content {
class WebContents;
}

namespace shaar::windows_tabs {

class BrowserTabRegistryImpl final : public shaar::BrowserTabRegistry {
 public:
  struct WindowState {
    shaar_engine* engine;
    shaar_window* handle;
    Browser* browser;
    Browser* active_browser = nullptr;
    std::string active_profile_id;
    std::unordered_map<std::string, Browser*> browsers_by_profile;
  };
  Browser* FindBrowser(shaar_engine*, shaar_window*) override;
  content::WebContents* FindWebContents(shaar_engine*, shaar_window*,
                                         shaar_tab*) override;
  content::WebContents* FindWebContentsByID(shaar_engine*, shaar_window*,
                                             std::string_view) override;
  std::string_view TabID(shaar_engine*, shaar_window*, shaar_tab*) override;
  void GetTabs(shaar_engine*, shaar_window*,
               std::unordered_map<std::string, content::WebContents*>*) override;
  void BindWindow(shaar_engine*, shaar_window*, Browser*);
  WindowState* EnsureWindowState(shaar_engine*, shaar_window*, Browser*,
                                 std::string_view profile_id);
  void BindTab(shaar_engine*, shaar_window*, shaar_tab*, std::string id,
               content::WebContents*);
  void UnbindWindow(shaar_engine*, shaar_window*);

 private:
  struct TabEntry {
    shaar_engine* engine;
    shaar_window* window;
    shaar_tab* handle;
    std::string id;
    content::WebContents* contents;
  };
  std::vector<WindowState> windows_;
  std::vector<TabEntry> tabs_;
};

BrowserTabRegistryImpl& Registry();

// Validates a complete caller order against the IDs currently bound to this
// strip. The caller must perform this check before mutating Chromium state.
bool ValidatePlacement(const std::vector<std::string>& requested_ids,
                       const std::vector<std::string>& current_ids,
                       const std::vector<std::string>& pinned_ids);

// Applies a previously validated complete order using the Chromium 155
// TabStripModel API. Tab IDs are caller-owned identities, never Chromium IDs.
bool ApplyPlacement(TabStripModel* model,
                    const std::vector<std::string>& requested_ids,
                    const std::unordered_map<std::string,
                                             content::WebContents*>& current_tabs,
                    const std::vector<std::string>& pinned_ids);

}  // namespace shaar::windows_tabs

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_
