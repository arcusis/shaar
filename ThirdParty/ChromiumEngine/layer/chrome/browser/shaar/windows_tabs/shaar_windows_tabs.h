// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_

#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "chrome/browser/shaar/engine/shaar_engine_context.h"

class TabStripModel;
class Browser;
class GURL;
class Profile;
namespace content {
class WebContents;
}
struct TabStripSelectionChange;

namespace shaar::windows_tabs {

struct SelectedRegularTab {
  shaar_engine* engine;
  shaar_window* window;
  shaar_tab* tab;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
};

bool ShouldEmitTabActivation(const TabStripSelectionChange& selection);

bool HasHiddenNativeWindow(content::WebContents* contents);
void UpdateDockedDevTools(content::WebContents* inspected,
                          content::WebContents* frontend);
// Routes a DevTools frontend request through the active Shaar-owned tab.
// A missing or ambiguous source is rejected, never shown in Chrome's Browser.
bool RouteDevToolsOpenURL(content::WebContents* source,
                          Profile* profile,
                          const GURL& url);

class BrowserTabRegistryImpl final : public shaar::BrowserTabRegistry {
 public:
  struct WindowState {
    shaar_engine* engine;
    shaar_window* handle;
    Browser* browser;
    // BEGIN find
    std::string window_id;
    // END find
    Browser* active_browser = nullptr;
    std::string active_profile_id;
    std::unordered_map<std::string, Browser*> browsers_by_profile;
    bool closing = false;
    std::unordered_set<Browser*> pending_closes;
  };
  Browser* FindBrowser(shaar_engine*, shaar_window*) override;
  bool IsSelectedWebContents(shaar_engine*, shaar_window*, shaar_tab*,
                             content::WebContents*) override;
  std::optional<SelectedRegularTab> FindSelectedRegularTab(
      shaar_engine*, content::WebContents*) const;
  std::optional<SelectedRegularTab> FindRegularTabForBrowser(
      Browser*, content::WebContents*) const;
  content::WebContents* FindWebContents(shaar_engine*, shaar_window*,
                                         shaar_tab*) override;
  content::WebContents* FindWebContentsByID(shaar_engine*, shaar_window*,
                                             std::string_view) override;
  content::WebContents* FindWebContentsByID(shaar_engine*, std::string_view);
  std::string_view TabID(shaar_engine*, shaar_window*, shaar_tab*) override;
  // BEGIN find
  std::string_view WindowID(shaar_engine*, shaar_window*) override;
  // Native window-open path: bind the reserved ABI handle to its public ID.
  void OnWindowOpened(shaar_engine*, shaar_window*, Browser*,
                      std::string window_id, std::string_view profile_id);
  void BindWindowID(shaar_engine*, shaar_window*, std::string window_id);
  // END find
  void GetTabs(shaar_engine*, shaar_window*,
               std::unordered_map<std::string, content::WebContents*>*) override;
  Browser* FindBrowserForTab(shaar_engine*, shaar_window*, shaar_tab*) const;
  void GetTabsForBrowser(
      shaar_engine*, shaar_window*, Browser*,
      std::unordered_map<std::string, content::WebContents*>*) const;
  // False when `browser` is null or was already retired while closing.
  bool BindWindow(shaar_engine*, shaar_window*, Browser*);
  bool ReserveWindow(shaar_engine*, shaar_window*, std::string id);
  bool ReserveTab(shaar_engine*, shaar_window*, shaar_tab*, std::string id);
  void UnbindTab(shaar_engine*, shaar_window*, shaar_tab*);
  void UnbindBrowser(shaar_engine*, shaar_window*, Browser*);
  // Drops every window's reference. Pointer identity only: safe after free.
  void RetireClosingBrowser(Browser*);
  bool BrowserHasBoundTabs(Browser*) const;
  bool IsClosingBrowser(Browser*) const;
  // Retires a still-live cached Browser once unload has started. The first
  // call must happen while the object is alive; later calls only compare.
  bool ReleaseIfClosing(Browser*);
  // Called only for a freshly allocated live Browser. Allocators may reuse
  // the address of a Browser that was retired during close.
  void MarkBrowserCreated(Browser*);
  void WatchBrowserClose(Browser*);
  bool BeginWindowClose(shaar_engine*, shaar_window*);
  void BeginEngineQuit(shaar_engine*);
  void CancelEngineQuit(shaar_engine*);
  bool EngineQuitRequested(shaar_engine*) const;
  bool WindowCloseReady(shaar_engine*, shaar_window*) const;
  WindowState* FindWindowState(shaar_engine*, shaar_window*);
  bool HasTabID(shaar_engine*, shaar_window*, std::string_view) const;
  WindowState* EnsureWindowState(shaar_engine*, shaar_window*, Browser*,
                                 std::string_view profile_id);
  void BindTab(shaar_engine*, shaar_window*, shaar_tab*, std::string id,
               Browser*, content::WebContents*);
  void UnbindWindow(shaar_engine*, shaar_window*);
  shaar_engine* FindWindowOwner(shaar_window*) const;
  shaar_window* FindTabWindow(shaar_tab*) const;

 private:
  struct TabEntry {
    shaar_engine* engine;
    shaar_window* window;
    shaar_tab* handle;
    std::string id;
    Browser* browser;
    content::WebContents* contents;
  };
  std::vector<WindowState> windows_;
  std::vector<TabEntry> tabs_;
  std::unordered_set<shaar_engine*> quitting_engines_;
  // Addresses stay retired so a freed Browser cannot be stored again.
  std::unordered_set<Browser*> retired_browsers_;
};

BrowserTabRegistryImpl& Registry();
void StopObservingLifecycle();

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
