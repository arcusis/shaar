// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/shaar/devtools/shaar_devtools_panel.h"
#include "chrome/browser/shaar/devtools/shaar_devtools_viewports.h"

#include <algorithm>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/windows_tabs/shaar_page_view_binding.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"

namespace shaar::windows_tabs {

namespace {
BrowserTabRegistryImpl g_registry;
}

BrowserTabRegistryImpl& Registry() { return g_registry; }

void BrowserTabRegistryImpl::BeginEngineQuit(shaar_engine* engine) {
  if (engine) {
    shaar::devtools::ClosePanelLeasesForEngine(engine);
    shaar::devtools::CloseViewportLeasesForEngine(engine);
    quitting_engines_.insert(engine);
  }
}

void BrowserTabRegistryImpl::CancelEngineQuit(shaar_engine* engine) {
  quitting_engines_.erase(engine);
}

bool BrowserTabRegistryImpl::EngineQuitRequested(shaar_engine* engine) const {
  return quitting_engines_.contains(engine);
}

BrowserTabRegistryImpl::WindowState* BrowserTabRegistryImpl::FindWindowState(
    shaar_engine* engine, shaar_window* window) {
  for (auto& entry : windows_)
    if (entry.engine == engine && entry.handle == window)
      return &entry;
  return nullptr;
}

bool BrowserTabRegistryImpl::ReserveWindow(shaar_engine* engine,
                                           shaar_window* window,
                                           std::string id) {
  if (!engine || !window || id.empty() || EngineQuitRequested(engine))
    return false;
  for (const auto& entry : windows_)
    if (entry.handle == window ||
        (entry.engine == engine && entry.window_id == id))
      return false;
  windows_.push_back({engine, window, nullptr, std::move(id), nullptr, {}, {}});
  return true;
}

bool BrowserTabRegistryImpl::HasTabID(shaar_engine* engine,
                                      shaar_window* window,
                                      std::string_view id) const {
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window && entry.id == id)
      return true;
  return false;
}

bool BrowserTabRegistryImpl::ReserveTab(shaar_engine* engine,
                                        shaar_window* window,
                                        shaar_tab* tab,
                                        std::string id) {
  if (!engine || !window || !tab || id.empty() || EngineQuitRequested(engine) ||
      !FindWindowState(engine, window) || HasTabID(engine, window, id))
    return false;
  for (const auto& entry : tabs_)
    if (entry.handle == tab)
      return false;
  tabs_.push_back({engine, window, tab, std::move(id), nullptr, nullptr});
  return true;
}

void BrowserTabRegistryImpl::UnbindTab(shaar_engine* engine,
                                       shaar_window* window,
                                       shaar_tab* tab) {
  shaar::devtools::ClosePanelLeaseForTab(FindWebContents(engine, window, tab));
  shaar::devtools::CloseViewportLeaseForTab(FindWebContents(engine, window, tab));
  std::erase_if(tabs_, [engine, window, tab](const TabEntry& entry) {
    return entry.engine == engine && entry.window == window &&
           entry.handle == tab;
  });
}

void BrowserTabRegistryImpl::UnbindBrowser(shaar_engine* engine,
                                           shaar_window* window,
                                           Browser* browser) {
  auto* state = FindWindowState(engine, window);
  if (!state || !browser)
    return;
  state->pending_closes.erase(browser);
  std::erase_if(state->browsers_by_profile,
                [browser](const auto& entry) { return entry.second == browser; });
  if (state->browser == browser)
    state->browser = nullptr;
  if (state->active_browser == browser) {
    state->active_browser = nullptr;
    state->active_profile_id.clear();
  }
  if (!state->browsers_by_profile.empty()) {
    const auto& [id, remaining] = *state->browsers_by_profile.begin();
    if (!state->browser)
      state->browser = remaining;
    if (!state->active_browser) {
      state->active_browser = remaining;
      state->active_profile_id = id;
    }
  }
}

bool BrowserTabRegistryImpl::BeginWindowClose(shaar_engine* engine,
                                              shaar_window* window) {
  auto* state = FindWindowState(engine, window);
  if (!state)
    return false;
  if (state->closing)
    return true;
  state->closing = true;
  if (state->browser)
    state->pending_closes.insert(state->browser);
  for (const auto& [id, browser] : state->browsers_by_profile)
    if (browser)
      state->pending_closes.insert(browser);
  return true;
}

bool BrowserTabRegistryImpl::WindowCloseReady(shaar_engine* engine,
                                              shaar_window* window) const {
  for (const auto& state : windows_)
    if (state.engine == engine && state.handle == window) {
      if (!state.closing || !state.pending_closes.empty())
        return false;
      return !std::ranges::any_of(tabs_, [engine, window](const TabEntry& tab) {
        return tab.engine == engine && tab.window == window;
      });
    }
  return false;
}

Browser* BrowserTabRegistryImpl::FindBrowser(shaar_engine* engine,
                                             shaar_window* window) {
  for (const auto& entry : windows_)
    if (entry.engine == engine && entry.handle == window)
      return entry.browser;
  return nullptr;
}

bool BrowserTabRegistryImpl::IsSelectedWebContents(
    shaar_engine* engine, shaar_window* window, shaar_tab* tab,
    content::WebContents* contents) {
  WindowState* state = FindWindowState(engine, window);
  Browser* owner = FindBrowserForTab(engine, window, tab);
  return state && contents && owner && state->active_browser == owner &&
         FindWebContents(engine, window, tab) == contents &&
         owner->tab_strip_model()->GetActiveWebContents() == contents;
}

std::optional<SelectedRegularTab>
BrowserTabRegistryImpl::FindSelectedRegularTab(
    shaar_engine* engine, content::WebContents* contents) const {
  if (!engine || !contents || EngineQuitRequested(engine))
    return std::nullopt;
  for (const auto& tab : tabs_) {
    if (tab.engine != engine || tab.contents != contents || !tab.browser ||
        tab.browser->GetProfile()->IsOffTheRecord())
      continue;
    for (const auto& window : windows_) {
      if (window.engine != engine || window.handle != tab.window ||
          window.closing || window.active_browser != tab.browser ||
          tab.browser->tab_strip_model()->GetActiveWebContents() != contents)
        continue;
      for (const auto& [profile_id, browser] : window.browsers_by_profile) {
        if (browser == tab.browser)
          return SelectedRegularTab{tab.window, tab.handle, profile_id,
                                    window.window_id, tab.id};
      }
    }
  }
  return std::nullopt;
}

content::WebContents* BrowserTabRegistryImpl::FindWebContents(
    shaar_engine* engine,
    shaar_window* window,
    shaar_tab* tab) {
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window &&
        entry.handle == tab)
      return entry.contents;
  return nullptr;
}

content::WebContents* BrowserTabRegistryImpl::FindWebContentsByID(
    shaar_engine* engine,
    shaar_window* window,
    std::string_view id) {
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window && entry.id == id)
      return entry.contents;
  return nullptr;
}

content::WebContents* BrowserTabRegistryImpl::FindWebContentsByID(
    shaar_engine* engine,
    std::string_view id) {
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.id == id)
      return entry.contents;
  return nullptr;
}

std::string_view BrowserTabRegistryImpl::TabID(shaar_engine* engine,
                                               shaar_window* window,
                                               shaar_tab* tab) {
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window &&
        entry.handle == tab)
      return entry.id;
  return {};
}

// BEGIN find
std::string_view BrowserTabRegistryImpl::WindowID(shaar_engine* engine,
                                                  shaar_window* window) {
  for (const auto& entry : windows_)
    if (entry.engine == engine && entry.handle == window)
      return entry.window_id;
  return {};
}

void BrowserTabRegistryImpl::BindWindowID(shaar_engine* engine,
                                          shaar_window* window,
                                          std::string window_id) {
  if (!engine || !window || window_id.empty())
    return;
  for (auto& entry : windows_) {
    if (entry.engine == engine && entry.handle == window) {
      entry.window_id = std::move(window_id);
      return;
    }
  }
}

void BrowserTabRegistryImpl::OnWindowOpened(shaar_engine* engine,
                                            shaar_window* window,
                                            Browser* browser,
                                            std::string window_id,
                                            std::string_view profile_id) {
  BindWindow(engine, window, browser);
  BindWindowID(engine, window, std::move(window_id));
  EnsureWindowState(engine, window, browser, profile_id);
}
// END find

void BrowserTabRegistryImpl::GetTabs(
    shaar_engine* engine,
    shaar_window* window,
    std::unordered_map<std::string, content::WebContents*>* tabs) {
  if (!tabs)
    return;
  tabs->clear();
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window)
      tabs->emplace(entry.id, entry.contents);
}

Browser* BrowserTabRegistryImpl::FindBrowserForTab(
    shaar_engine* engine, shaar_window* window, shaar_tab* tab) const {
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window &&
        entry.handle == tab)
      return entry.browser;
  return nullptr;
}

void BrowserTabRegistryImpl::GetTabsForBrowser(
    shaar_engine* engine, shaar_window* window, Browser* browser,
    std::unordered_map<std::string, content::WebContents*>* tabs) const {
  if (!tabs)
    return;
  tabs->clear();
  for (const auto& entry : tabs_)
    if (entry.engine == engine && entry.window == window &&
        entry.browser == browser && entry.contents)
      tabs->emplace(entry.id, entry.contents);
}

void BrowserTabRegistryImpl::BindWindow(shaar_engine* engine,
                                        shaar_window* window,
                                        Browser* browser) {
  if (!engine || !window || !browser)
    return;
  for (auto& entry : windows_) {
    if (entry.engine == engine && entry.handle == window) {
      entry.browser = browser;
      if (!entry.active_browser)
        entry.active_browser = browser;
      return;
    }
  }
  windows_.push_back({engine, window, browser, {}, browser, {}, {}});
}

BrowserTabRegistryImpl::WindowState* BrowserTabRegistryImpl::EnsureWindowState(
    shaar_engine* engine,
    shaar_window* window,
    Browser* browser,
    std::string_view profile_id) {
  BindWindow(engine, window, browser);
  for (auto& entry : windows_) {
    if (entry.engine == engine && entry.handle == window) {
      if (!profile_id.empty()) {
        entry.browsers_by_profile.emplace(std::string(profile_id), browser);
        if (entry.active_profile_id.empty())
          entry.active_profile_id = profile_id;
      }
      return &entry;
    }
  }
  return nullptr;
}

void BrowserTabRegistryImpl::BindTab(shaar_engine* engine,
                                     shaar_window* window,
                                     shaar_tab* tab,
                                     std::string id,
                                     Browser* browser,
                                     content::WebContents* contents) {
  if (!engine || !window || !tab || id.empty() || !browser || !contents)
    return;
  for (auto& entry : tabs_) {
    if (entry.engine == engine && entry.window == window &&
        entry.handle == tab) {
      entry.id = std::move(id);
      entry.browser = browser;
      entry.contents = contents;
      return;
    }
  }
  tabs_.push_back({engine, window, tab, std::move(id), browser, contents});
}

void BrowserTabRegistryImpl::UnbindWindow(shaar_engine* engine,
                                          shaar_window* window) {
  ReleasePageHost(window);
  std::erase_if(tabs_, [engine, window](const TabEntry& entry) {
    return entry.engine == engine && entry.window == window;
  });
  std::erase_if(windows_, [engine, window](const WindowState& entry) {
    return entry.engine == engine && entry.handle == window;
  });
}

shaar_engine* BrowserTabRegistryImpl::FindWindowOwner(
    shaar_window* window) const {
  for (const auto& entry : windows_)
    if (entry.handle == window)
      return entry.engine;
  return nullptr;
}

shaar_window* BrowserTabRegistryImpl::FindTabWindow(shaar_tab* tab) const {
  for (const auto& entry : tabs_)
    if (entry.handle == tab)
      return entry.window;
  return nullptr;
}

bool ValidatePlacement(const std::vector<std::string>& requested_ids,
                       const std::vector<std::string>& current_ids,
                       const std::vector<std::string>& pinned_ids) {
  const std::unordered_set<std::string> current(current_ids.begin(),
                                                 current_ids.end());
  const std::unordered_set<std::string> requested(requested_ids.begin(),
                                                   requested_ids.end());
  const std::unordered_set<std::string> pinned(pinned_ids.begin(),
                                                pinned_ids.end());
  if (current.size() != current_ids.size() ||
      requested.size() != requested_ids.size() ||
      pinned.size() != pinned_ids.size() || requested != current)
    return false;
  bool encountered_unpinned = false;
  for (const auto& id : requested_ids) {
    if (pinned.contains(id)) {
      if (encountered_unpinned)
        return false;
    } else {
      encountered_unpinned = true;
    }
  }
  return std::all_of(pinned.begin(), pinned.end(),
                     [&current](const auto& id) { return current.contains(id); });
}

bool ApplyPlacement(TabStripModel* model,
                    const std::vector<std::string>& requested_ids,
                    const std::unordered_map<std::string,
                                             content::WebContents*>& current_tabs,
                    const std::vector<std::string>& pinned_ids) {
  std::vector<std::string> current_ids;
  current_ids.reserve(current_tabs.size());
  for (const auto& [id, contents] : current_tabs) {
    if (id.empty() || !contents)
      return false;
    current_ids.push_back(id);
  }
  if (!model || !ValidatePlacement(requested_ids, current_ids, pinned_ids) ||
      model->count() != static_cast<int>(current_tabs.size()))
    return false;

  // Pin state changes can relocate a tab. Apply them before resolving indices,
  // then locate each requested tab against the live model for each move.
  std::unordered_set<content::WebContents*> unique_contents;
  for (const auto& [id, contents] : current_tabs) {
    if (!unique_contents.insert(contents).second ||
        model->GetIndexOfWebContents(contents) < 0)
      return false;
  }
  const std::unordered_set<std::string> pinned(pinned_ids.begin(),
                                                pinned_ids.end());
  for (const auto& [id, contents] : current_tabs) {
    const int live_index = model->GetIndexOfWebContents(contents);
    if (live_index < 0 || model->IsTabPinned(live_index) == pinned.contains(id))
      continue;
    model->SetTabPinned(live_index, pinned.contains(id));
  }
  for (size_t target = 0; target < requested_ids.size(); ++target) {
    auto* contents = current_tabs.at(requested_ids[target]);
    const int from = model->GetIndexOfWebContents(contents);
    if (from >= 0 && from != static_cast<int>(target))
      model->MoveWebContentsAt(from, static_cast<int>(target), false);
  }
  return true;
}

}  // namespace shaar::windows_tabs
