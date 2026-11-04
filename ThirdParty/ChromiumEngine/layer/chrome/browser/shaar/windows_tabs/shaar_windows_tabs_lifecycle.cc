// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/public/shaar_engine.h"

#include <pthread.h>

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/scoped_observation.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/navigation/shaar_navigation.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"

struct shaar_window {
  shaar_engine* engine;
  shaar_window_kind kind;
  shaar_private_session* private_session;
  std::string id;
  std::string profile_id;
};

void CleanupTab(shaar_tab* tab, uint64_t serial);

struct shaar_tab : content::WebContentsObserver {
  shaar_tab(content::WebContents* contents, uint64_t serial)
      : content::WebContentsObserver(contents), serial(serial) {}
  void WebContentsDestroyed() override {
    shaar::windows_tabs::Registry().UnbindTab(engine, window, this);
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&CleanupTab, this, serial));
  }
  const uint64_t serial;
  shaar_engine* engine;
  shaar_window* window;
  Browser* browser;
  shaar_profile* profile;
  shaar_private_session* private_session;
  std::string profile_id;
  std::string session_id;
  std::string window_id;
  std::string tab_id;
  std::unique_ptr<shaar::navigation::NavigationObserver> navigation;
};

namespace {

std::unordered_map<shaar_window*, std::unique_ptr<shaar_window>> windows;
std::unordered_map<shaar_tab*, std::unique_ptr<shaar_tab>> tabs;
uint64_t next_tab_serial = 0;

void FinalizeWindow(shaar_window* window);

class LifecycleObserver final : public BrowserCollectionObserver {
 public:
  void EnsureObserving() {
    if (!observation_.IsObserving()) {
      if (auto* collection = GlobalBrowserCollection::GetInstance())
        observation_.Observe(collection);
    }
  }

  void OnBrowserClosed(BrowserWindowInterface* closed) override {
    auto* browser = static_cast<Browser*>(closed);
    auto& registry = shaar::windows_tabs::Registry();
    std::vector<shaar_window*> finished;
    for (const auto& [window, handle] : windows) {
      registry.UnbindBrowser(handle->engine, window, browser);
      if (registry.WindowCloseReady(handle->engine, window))
        finished.push_back(window);
    }
    for (const auto& [tab, handle] : tabs)
      if (handle->browser == browser)
        handle->browser = nullptr;
    for (shaar_window* window : finished)
      FinalizeWindow(window);
  }

 private:
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      observation_{this};
};

LifecycleObserver& Observer() {
  static LifecycleObserver observer;
  return observer;
}

shaar_error_code Result(shaar_error_code status, shaar_error* error) {
  if (error && error->size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = status;
  return status;
}

void FinalizeWindow(shaar_window* window) {
  auto found = windows.find(window);
  if (found == windows.end())
    return;
  shaar_engine* engine = window->engine;
  const std::string window_id = window->id;
  const std::string profile_id = window->profile_id;
  struct ClosedTab {
    std::string profile_id;
    std::string session_id;
    std::string id;
  };
  std::vector<ClosedTab> closed_tabs;
  for (auto it = tabs.begin(); it != tabs.end();) {
    if (it->second->window == window) {
      closed_tabs.push_back({it->second->profile_id, it->second->session_id,
                             it->second->tab_id});
      it = tabs.erase(it);
    } else {
      ++it;
    }
  }
  shaar::windows_tabs::Registry().UnbindWindow(engine, window);
  windows.erase(found);
  static constexpr char kClosed[] = R"({"kind":"closed","schemaVersion":1})";
  for (const auto& tab : closed_tabs) {
    shaar::EmitEvent(engine, SHAAR_EVENT_TAB,
                     {tab.profile_id.data(), tab.profile_id.size()},
                     {tab.session_id.data(), tab.session_id.size()},
                     {window_id.data(), window_id.size()},
                     {tab.id.data(), tab.id.size()},
                     {kClosed, sizeof(kClosed) - 1});
  }
  if (!profile_id.empty()) {
    shaar::EmitEvent(engine, SHAAR_EVENT_WINDOW,
                     {profile_id.data(), profile_id.size()}, {},
                     {window_id.data(), window_id.size()}, {},
                     {kClosed, sizeof(kClosed) - 1});
  }
}

bool ValidID(shaar_bytes bytes) {
  return bytes.data && bytes.size &&
         std::string_view(bytes.data, bytes.size).find('\0') ==
             std::string_view::npos;
}

bool ValidURL(shaar_bytes bytes) {
  return bytes.size == 0 ||
         (bytes.data && std::string_view(bytes.data, bytes.size).find('\0') ==
                            std::string_view::npos);
}

Browser* CreateHiddenBrowser(Profile* profile) {
  if (!profile)
    return nullptr;
  Observer().EnsureObserving();
  BrowserWindowCreateParams params(profile, false);
  params.omit_from_session_restore = true;
  params.should_trigger_session_restore = false;
  BrowserWindowInterface* created = CreateBrowserWindow(std::move(params));
  return static_cast<Browser*>(created);
}

Profile* ResolveScope(shaar_engine* engine,
                      shaar_window* window,
                      shaar_scope scope,
                      shaar_error_code* status) {
  auto& context = shaar::EngineContext();
  if (scope.size < sizeof(shaar_scope) ||
      static_cast<bool>(scope.profile) ==
          static_cast<bool>(scope.private_session)) {
    *status = SHAAR_INVALID_ARGUMENT;
    return nullptr;
  }
  if (window->kind == SHAAR_WINDOW_PRIVATE) {
    if (scope.private_session != window->private_session ||
        !context.private_sessions) {
      *status = SHAAR_WRONG_SESSION;
      return nullptr;
    }
    Profile* parent = nullptr;
    Profile* otr = nullptr;
    std::string_view profile_id;
    std::string_view session_id;
    if (!context.private_sessions->Resolve(engine, scope.private_session,
                                           &parent, &otr, &profile_id,
                                           &session_id)) {
      *status = SHAAR_NOT_FOUND;
      return nullptr;
    }
    *status = SHAAR_OK;
    return otr;
  }
  if (scope.private_session || !scope.profile || !context.profile_services) {
    *status = SHAAR_WRONG_PROFILE;
    return nullptr;
  }
  Profile* profile =
      context.profile_services->ResolveProfile(engine, scope.profile);
  *status = profile ? SHAAR_OK : SHAAR_NOT_FOUND;
  return profile;
}

Browser* BrowserForScope(shaar_engine* engine,
                         shaar_window* window,
                         shaar_scope scope,
                         Profile* profile) {
  auto& registry = shaar::windows_tabs::Registry();
  auto* state = registry.FindWindowState(engine, window);
  if (!state)
    return nullptr;
  if (window->kind == SHAAR_WINDOW_PRIVATE) {
    if (state->browser)
      return state->browser;
    Browser* browser = CreateHiddenBrowser(profile);
    registry.BindWindow(engine, window, browser);
    return browser;
  }
  const std::string id(shaar::EngineContext().profile_services->ProfileID(
      engine, scope.profile));
  if (id.empty())
    return nullptr;
  auto found = state->browsers_by_profile.find(id);
  if (found != state->browsers_by_profile.end())
    return found->second;
  Browser* browser = CreateHiddenBrowser(profile);
  if (browser)
    registry.EnsureWindowState(engine, window, browser, id);
  return browser;
}

}  // namespace

extern "C" SHAAR_EXPORT shaar_error_code shaar_window_open(
    shaar_engine* engine,
    shaar_window_kind kind,
    shaar_private_session* private_session,
    shaar_bytes window_id,
    shaar_window** out,
    shaar_error* error) {
  if (out)
    *out = nullptr;
  if (!pthread_main_np() || !engine || !out || !ValidID(window_id) ||
      (kind != SHAAR_WINDOW_REGULAR && kind != SHAAR_WINDOW_PRIVATE) ||
      (kind == SHAAR_WINDOW_REGULAR && private_session) ||
      (kind == SHAAR_WINDOW_PRIVATE && !private_session))
    return Result(SHAAR_INVALID_ARGUMENT, error);

  Profile* private_profile = nullptr;
  std::string private_profile_id;
  if (kind == SHAAR_WINDOW_PRIVATE) {
    auto* services = shaar::EngineContext().private_sessions;
    Profile* parent = nullptr;
    std::string_view profile_id;
    std::string_view session_id;
    if (!services || !services->Resolve(engine, private_session, &parent,
                                        &private_profile, &profile_id,
                                        &session_id))
      return Result(SHAAR_NOT_FOUND, error);
    private_profile_id = profile_id;
  }

  auto handle = std::make_unique<shaar_window>();
  handle->engine = engine;
  handle->kind = kind;
  handle->private_session = private_session;
  handle->id.assign(window_id.data, window_id.size);
  handle->profile_id = std::move(private_profile_id);
  auto* raw = handle.get();
  auto& registry = shaar::windows_tabs::Registry();
  if (!registry.ReserveWindow(engine, raw,
                              std::string(window_id.data, window_id.size)))
    return Result(SHAAR_CONFLICT, error);
  if (private_profile) {
    Browser* browser = CreateHiddenBrowser(private_profile);
    if (!browser) {
      registry.UnbindWindow(engine, raw);
      return Result(SHAAR_CHROMIUM_ERROR, error);
    }
    registry.BindWindow(engine, raw, browser);
  }
  windows.emplace(raw, std::move(handle));
  *out = raw;
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_window_close(
    shaar_window* window, shaar_error* error) {
  if (!pthread_main_np() || !window)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = windows.find(window);
  if (found == windows.end())
    return Result(SHAAR_NOT_FOUND, error);
  shaar_engine* engine = window->engine;
  auto& registry = shaar::windows_tabs::Registry();
  auto* state = registry.FindWindowState(engine, window);
  if (!state)
    return Result(SHAAR_NOT_FOUND, error);
  if (!registry.BeginWindowClose(engine, window))
    return Result(SHAAR_CONFLICT, error);
  const std::vector<Browser*> pending(state->pending_closes.begin(),
                                      state->pending_closes.end());
  if (pending.empty()) {
    FinalizeWindow(window);
    return Result(SHAAR_OK, error);
  }
  for (Browser* browser : pending)
    if (browser && browser->GetWindow())
      browser->GetWindow()->Close();
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_open(
    shaar_scope scope,
    shaar_window* window,
    shaar_bytes tab_id,
    shaar_bytes url,
    int foreground,
    shaar_tab** out,
    shaar_error* error) {
  if (out)
    *out = nullptr;
  if (!pthread_main_np() || !window || !out || !ValidID(tab_id) ||
      !ValidURL(url) || (foreground != 0 && foreground != 1))
    return Result(SHAAR_INVALID_ARGUMENT, error);
  std::string target;
  if (url.size) {
    const shaar_error_code validation = shaar::navigation::ValidateURL(
        std::string(url.data, url.size), &target);
    if (validation != SHAAR_OK)
      return Result(validation, error);
  }
  if (!windows.contains(window))
    return Result(SHAAR_NOT_FOUND, error);
  shaar_engine* engine = window->engine;
  shaar_error_code status = SHAAR_OK;
  Profile* profile = ResolveScope(engine, window, scope, &status);
  if (!profile)
    return Result(status, error);
  auto& registry = shaar::windows_tabs::Registry();
  auto* state = registry.FindWindowState(engine, window);
  if (!state || state->closing)
    return Result(SHAAR_CONFLICT, error);
  if (registry.HasTabID(engine, window,
                        std::string_view(tab_id.data, tab_id.size)))
    return Result(SHAAR_CONFLICT, error);
  Browser* browser = BrowserForScope(engine, window, scope, profile);
  if (!browser)
    return Result(SHAAR_CHROMIUM_ERROR, error);
  auto contents = content::WebContents::Create(
      content::WebContents::CreateParams(profile));
  if (!contents)
    return Result(SHAAR_CHROMIUM_ERROR, error);
  content::WebContents* raw_contents = contents.get();
  browser->GetTabStripModel()->AppendWebContents(std::move(contents),
                                                 foreground != 0);
  auto handle = std::make_unique<shaar_tab>(raw_contents, ++next_tab_serial);
  handle->engine = engine;
  handle->window = window;
  handle->browser = browser;
  handle->profile = scope.profile;
  handle->private_session = scope.private_session;
  handle->window_id = std::string(registry.WindowID(engine, window));
  handle->tab_id = std::string(tab_id.data, tab_id.size);
  if (scope.profile) {
    handle->profile_id = std::string(
        shaar::EngineContext().profile_services->ProfileID(engine, scope.profile));
  } else {
    Profile* parent = nullptr;
    Profile* otr = nullptr;
    std::string_view profile_id;
    std::string_view session_id;
    shaar::EngineContext().private_sessions->Resolve(
        engine, scope.private_session, &parent, &otr, &profile_id, &session_id);
    handle->profile_id = profile_id;
    handle->session_id = session_id;
  }
  handle->navigation = std::make_unique<shaar::navigation::NavigationObserver>(
      engine, raw_contents, handle->profile_id, handle->session_id,
      handle->window_id, handle->tab_id);
  auto* raw = handle.get();
  if (!registry.ReserveTab(engine, window, raw,
                           std::string(tab_id.data, tab_id.size)))
    return Result(SHAAR_CONFLICT, error);
  registry.BindTab(engine, window, raw,
                   std::string(tab_id.data, tab_id.size), browser,
                   raw_contents);
  tabs.emplace(raw, std::move(handle));
  if (window->profile_id.empty())
    window->profile_id = tabs.at(raw)->profile_id;
  *out = raw;
  if (url.size)
    shaar::navigation::Navigate(raw_contents, target, false);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_close(
    shaar_tab* tab, shaar_error* error) {
  if (!pthread_main_np() || !tab)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = tabs.find(tab);
  if (found == tabs.end())
    return Result(SHAAR_NOT_FOUND, error);
  auto& registry = shaar::windows_tabs::Registry();
  content::WebContents* contents =
      registry.FindWebContents(tab->engine, tab->window, tab);
  Browser* browser = tab->browser;
  if (!contents || !browser)
    return Result(SHAAR_NOT_FOUND, error);
  TabStripModel* model = browser->GetTabStripModel();
  const int index = model->GetIndexOfWebContents(contents);
  if (index < 0)
    return Result(SHAAR_NOT_FOUND, error);
  model->CloseWebContentsAt(index, 0);
  return Result(SHAAR_OK, error);
}

void CleanupTab(shaar_tab* tab, uint64_t serial) {
  auto found = tabs.find(tab);
  if (found == tabs.end() || found->second->serial != serial)
    return;
  const std::string profile_id = tab->profile_id;
  const std::string session_id = tab->session_id;
  const std::string window_id = tab->window_id;
  const std::string tab_id = tab->tab_id;
  shaar_engine* engine = tab->engine;
  shaar::windows_tabs::Registry().UnbindTab(tab->engine, tab->window, tab);
  tabs.erase(found);
  static constexpr char kClosed[] = R"({"kind":"closed","schemaVersion":1})";
  shaar::EmitEvent(engine, SHAAR_EVENT_TAB,
                   {profile_id.data(), profile_id.size()},
                   {session_id.data(), session_id.size()},
                   {window_id.data(), window_id.size()},
                   {tab_id.data(), tab_id.size()},
                   {kClosed, sizeof(kClosed) - 1});
}
