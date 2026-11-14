// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/public/shaar_engine.h"

#include <pthread.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/memory/ref_counted_memory.h"
#include "base/scoped_observation.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "chrome/browser/printing/print_view_manager.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/extensions/shaar_extensions.h"
#include "chrome/browser/shaar/media/shaar_media.h"
#include "chrome/browser/shaar/devtools/shaar_agent_bridge.h"
#include "chrome/browser/shaar/navigation/shaar_navigation.h"
#include "chrome/browser/shaar/tab_lifecycle/shaar_tab_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/shaar/save_prompts/shaar_save_prompts.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

struct shaar_window {
  uint64_t generation;
  shaar_engine* engine;
  shaar_window_kind kind;
  shaar_private_session* private_session;
  std::string id;
  std::string profile_id;
  std::string session_id;
};

void CleanupTab(uint64_t serial);
struct shaar_tab;
void RebindFavicon(shaar_tab* tab);
void RetargetDiscardedTab(shaar_tab* tab, content::WebContents* new_contents);

struct shaar_tab : content::WebContentsObserver,
                   favicon::FaviconDriverObserver {
  shaar_tab(content::WebContents* contents, uint64_t serial)
      : content::WebContentsObserver(contents), serial(serial) {}
  void RetargetWebContents(content::WebContents* contents) {
    Observe(contents);
  }
  void AboutToBeDiscarded(content::WebContents* new_contents) override {
    RetargetDiscardedTab(this, new_contents);
  }
  void WasDiscarded() override {
    // Replace-path discard attaches tab helpers, including the favicon
    // driver, only after AboutToBeDiscarded returns.
    RebindFavicon(this);
    shaar::tab_lifecycle::NoteDiscarded(engine, profile_id, session_id,
                                        window_id, tab_id, web_contents());
  }
  void WebContentsDestroyed() override {
    shaar::save_prompts::DismissSavePromptsForDestroyedContents(
        web_contents());
    favicon_observation.Reset();
    // Drop the WebContents pointer before a queued view update can request it.
    shaar::agent_bridge::RevokeForTab(engine, this);
    shaar::windows_tabs::Registry().UnbindTab(engine, window, this);
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&CleanupTab, serial));
  }
  void OnFaviconUpdated(favicon::FaviconDriver* driver,
                        NotificationIconType icon_type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override {
    if (icon_type != NON_TOUCH_16_DIP)
      return;
    favicon_png.clear();
    if (navigation)
      navigation->EmitInitialState();
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
  shaar::media::MediaTrackerPtr media{nullptr, nullptr};
  base::ScopedObservation<favicon::FaviconDriver,
                          favicon::FaviconDriverObserver>
      favicon_observation{this};
  std::string favicon_png;
};

void RebindFavicon(shaar_tab* tab) {
  if (!tab || tab->favicon_observation.IsObserving())
    return;
  content::WebContents* contents = tab->web_contents();
  if (!contents)
    return;
  if (auto* driver = favicon::ContentFaviconDriver::FromWebContents(contents))
    tab->favicon_observation.Observe(driver);
}

void RetargetDiscardedTab(shaar_tab* tab, content::WebContents* new_contents) {
  // The preserve path discards in place and passes the same WebContents.
  if (!tab || !new_contents || new_contents == tab->web_contents())
    return;
  const bool can_bind =
      tab->engine && tab->window && tab->browser && !tab->tab_id.empty();
  if (!can_bind) {
    shaar::windows_tabs::Registry().UnbindTab(tab->engine, tab->window, tab);
    tab->RetargetWebContents(nullptr);
    tab->favicon_observation.Reset();
    return;
  }
  auto& registry = shaar::windows_tabs::Registry();
  registry.UnbindTab(tab->engine, tab->window, tab);
  tab->RetargetWebContents(new_contents);
  registry.BindTab(tab->engine, tab->window, tab, tab->tab_id, tab->browser,
                   new_contents);
  if (registry.FindWebContents(tab->engine, tab->window, tab) != new_contents) {
    registry.UnbindTab(tab->engine, tab->window, tab);
    tab->RetargetWebContents(nullptr);
    tab->favicon_observation.Reset();
    return;
  }
  tab->favicon_observation.Reset();
}

namespace {

std::unordered_map<shaar_window*, std::unique_ptr<shaar_window>> windows;
std::unordered_map<shaar_tab*, std::unique_ptr<shaar_tab>> tab_handles;
// Keep retired addresses unavailable for the lifetime of the engine. The ABI
// passes opaque pointers without a generation token, so allocator reuse would
// otherwise allow a stale pointer to name a different live window or tab.
std::vector<std::unique_ptr<shaar_window>> retired_windows;
std::vector<std::unique_ptr<shaar_tab>> retired_tabs;
uint64_t next_window_generation = 0;
uint64_t next_tab_serial = 0;

shaar_window* LiveWindow(shaar_window* window) {
  auto found = windows.find(window);
  if (found == windows.end())
    return nullptr;
  shaar_window* owned = found->second.get();
  if (!owned->generation || !shaar::EngineIsLive(owned->engine) ||
      shaar::windows_tabs::Registry().FindWindowOwner(owned) != owned->engine)
    return nullptr;
  return owned;
}

bool LiveTab(shaar_tab* tab) {
  auto found = tab_handles.find(tab);
  return found != tab_handles.end() && found->second->serial != 0 &&
         found->second->serial == tab->serial &&
         shaar::windows_tabs::Registry().FindTabWindow(tab) ==
             found->second->window;
}

void FinalizeWindow(shaar_window* window);

class LifecycleObserver final : public BrowserCollectionObserver {
 public:
  void EnsureObserving() {
    if (!observation_.IsObserving()) {
      if (auto* collection = GlobalBrowserCollection::GetInstance())
        observation_.Observe(collection);
    }
  }

  void StopObserving() { observation_.Reset(); }

  void OnBrowserClosed(BrowserWindowInterface* closed) override {
    auto* browser = static_cast<Browser*>(closed);
    auto& registry = shaar::windows_tabs::Registry();
    for (const auto& [window, handle] : windows)
      shaar::extensions_host::ClosePopupsForBrowser(handle->engine, browser);
    std::vector<shaar_window*> finished;
    for (const auto& [window, handle] : windows) {
      registry.UnbindBrowser(handle->engine, window, browser);
      if (registry.WindowCloseReady(handle->engine, window))
        finished.push_back(window);
    }
    for (const auto& [tab, handle] : tab_handles)
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
  for (const auto& [tab, handle] : tab_handles)
    if (handle->window == window)
      return;
  shaar_engine* engine = window->engine;
  shaar::agent_bridge::RevokeForWindow(engine, window);
  shaar::extensions_host::ClosePopupsForWindow(engine, window);
  const std::string window_id = window->id;
  const std::string profile_id = window->profile_id;
  const std::string session_id = window->session_id;
  shaar_private_session *private_session = window->private_session;
  shaar::windows_tabs::Registry().UnbindWindow(engine, window);
  retired_windows.push_back(std::move(found->second));
  windows.erase(found);
  static constexpr char kClosed[] = R"({"kind":"closed","schemaVersion":1})";
  if (!profile_id.empty()) {
    shaar::EmitEvent(engine, SHAAR_EVENT_WINDOW,
                     {profile_id.data(), profile_id.size()},
                     {session_id.data(), session_id.size()},
                     {window_id.data(), window_id.size()}, {},
                     {kClosed, sizeof(kClosed) - 1});
  }
  if (private_session && shaar::EngineContext().private_sessions)
    shaar::EngineContext().private_sessions->ReleaseChild(engine,
                                                          private_session);
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
  Browser* browser = static_cast<Browser*>(created);
  if (browser) {
    if (BrowserWindow* native_window = BrowserWindow::FromBrowser(browser))
      native_window->Hide();
  }
  return browser;
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

namespace shaar::windows_tabs {
void StopObservingLifecycle() {
  Observer().StopObserving();
}

bool RouteDevToolsOpenURL(content::WebContents* source,
                          Profile* profile,
                          const GURL& url) {
  if (!pthread_main_np() || !profile || !url.is_valid() ||
      url.spec().size() > 8192 ||
      !(url.SchemeIsHTTPOrHTTPS() ||
        (url.SchemeIs("devtools") && url.host() == "devtools" &&
         (url.path() == "/bundled/js_app.html" ||
          url.path() == "/bundled/inspector.html" ||
          url.path() == "/bundled/node_app.html"))))
    return false;
  shaar_tab* selected = nullptr;
  for (const auto& [tab, handle] : tab_handles) {
    if (!LiveTab(tab) || !LiveWindow(handle->window))
      continue;
    content::WebContents* contents = Registry().FindWebContents(
        handle->engine, handle->window, tab);
    if (!contents || (profile && contents->GetBrowserContext() != profile))
      continue;
    if (source) {
      if (contents != source)
        continue;
    } else if (!Registry().IsSelectedWebContents(handle->engine,
                                                handle->window, tab, contents)) {
      continue;
    }
    if (selected)
      return false;
    selected = tab;
  }
  if (!selected)
    return false;
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "openURLRequested");
  payload.Set("sourceWindowID", selected->window_id);
  payload.Set("sourceTabID", selected->tab_id);
  payload.Set("profileID", selected->profile_id);
  payload.Set("url", url.spec());
  payload.Set("disposition", "newForegroundTab");
  std::string body;
  if (!base::JSONWriter::Write(base::Value(std::move(payload)), &body))
    return false;
  shaar::EmitEvent(selected->engine, SHAAR_EVENT_DEVTOOLS,
                   {selected->profile_id.data(), selected->profile_id.size()},
                   {selected->session_id.data(), selected->session_id.size()},
                   {selected->window_id.data(), selected->window_id.size()},
                   {selected->tab_id.data(), selected->tab_id.size()},
                   {body.data(), body.size()});
  return true;
}
}  // namespace shaar::windows_tabs

extern "C" SHAAR_EXPORT shaar_error_code shaar_window_open(
    shaar_engine* engine,
    shaar_window_kind kind,
    shaar_private_session* private_session,
    shaar_bytes window_id,
    shaar_window** out,
    shaar_error* error) {
  if (out)
    *out = nullptr;
  if (!pthread_main_np() || !engine || !out)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  if (!shaar::EngineIsLive(engine))
    return Result(SHAAR_NOT_FOUND, error);
  if (!ValidID(window_id) ||
      (kind != SHAAR_WINDOW_REGULAR && kind != SHAAR_WINDOW_PRIVATE) ||
      (kind == SHAAR_WINDOW_REGULAR && private_session) ||
      (kind == SHAAR_WINDOW_PRIVATE && !private_session))
    return Result(SHAAR_INVALID_ARGUMENT, error);
  if (shaar::windows_tabs::Registry().EngineQuitRequested(engine))
    return Result(SHAAR_SHUTTING_DOWN, error);

  Profile* private_profile = nullptr;
  std::string private_profile_id;
  std::string private_session_id;
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
    private_session_id = session_id;
  }

  auto handle = std::make_unique<shaar_window>();
  handle->generation = ++next_window_generation;
  handle->engine = engine;
  handle->kind = kind;
  handle->private_session = private_session;
  handle->id.assign(window_id.data, window_id.size);
  handle->profile_id = std::move(private_profile_id);
  handle->session_id = std::move(private_session_id);
  auto* raw = handle.get();
  auto& registry = shaar::windows_tabs::Registry();
  if (!registry.ReserveWindow(engine, raw,
                              std::string(window_id.data, window_id.size)))
    return Result(SHAAR_CONFLICT, error);
  if (private_profile) {
    auto *services = shaar::EngineContext().private_sessions;
    if (!services->RetainChild(engine, private_session)) {
      registry.UnbindWindow(engine, raw);
      return Result(SHAAR_NOT_FOUND, error);
    }
    Browser* browser = CreateHiddenBrowser(private_profile);
    if (!browser) {
      services->ReleaseChild(engine, private_session);
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
  window = LiveWindow(window);
  if (!window)
    return Result(SHAAR_NOT_FOUND, error);
  shaar_engine* engine = window->engine;
  auto& registry = shaar::windows_tabs::Registry();
  auto* state = registry.FindWindowState(engine, window);
  if (!state)
    return Result(SHAAR_NOT_FOUND, error);
  if (!registry.BeginWindowClose(engine, window))
    return Result(SHAAR_CONFLICT, error);
  shaar::extensions_host::ClosePopupsForWindow(engine, window);
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
  if (!pthread_main_np() || !window || !out)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  window = LiveWindow(window);
  if (!window)
    return Result(SHAAR_NOT_FOUND, error);
  if (!ValidID(tab_id) || !ValidURL(url) ||
      (foreground != 0 && foreground != 1))
    return Result(SHAAR_INVALID_ARGUMENT, error);
  std::string target;
  shaar_engine* engine = window->engine;
  if (shaar::windows_tabs::Registry().EngineQuitRequested(engine))
    return Result(SHAAR_SHUTTING_DOWN, error);
  shaar_error_code status = SHAAR_OK;
  Profile* profile = ResolveScope(engine, window, scope, &status);
  if (!profile)
    return Result(status, error);
  bool pending_node_frontend = false;
  if (url.size) {
    const GURL requested(std::string(url.data, url.size));
    pending_node_frontend = requested.SchemeIs("devtools") &&
        shaar::devtools::HasPendingNodeFrontend(profile, requested);
    if (pending_node_frontend) {
      target = requested.spec();
    } else {
      const shaar_error_code validation = shaar::navigation::ValidateURL(
          std::string(url.data, url.size), &target);
      if (validation != SHAAR_OK)
        return Result(validation, error);
    }
  }
  auto& registry = shaar::windows_tabs::Registry();
  auto* state = registry.FindWindowState(engine, window);
  if (!state || state->closing)
    return Result(SHAAR_NOT_FOUND, error);
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
  handle->media = shaar::media::CreateMediaTracker(
      engine, raw_contents, handle->profile_id, handle->session_id,
      handle->window_id, handle->tab_id);
  if (auto* driver = favicon::ContentFaviconDriver::FromWebContents(
          raw_contents)) {
    handle->favicon_observation.Observe(driver);
  }
  auto* raw = handle.get();
  if (!registry.ReserveTab(engine, window, raw,
                           std::string(tab_id.data, tab_id.size)))
    return Result(SHAAR_CONFLICT, error);
  registry.BindTab(engine, window, raw,
                   std::string(tab_id.data, tab_id.size), browser,
                   raw_contents);
  tab_handles.emplace(raw, std::move(handle));
  if (window->profile_id.empty())
    window->profile_id = tab_handles.at(raw)->profile_id;
  *out = raw;
  if (url.size) {
    if (pending_node_frontend) {
      if (!shaar::devtools::OpenPendingNodeFrontend(raw_contents, profile,
                                                    GURL(target))) {
        const int index = browser->GetTabStripModel()->GetIndexOfWebContents(
            raw_contents);
        if (index >= 0)
          browser->GetTabStripModel()->CloseWebContentsAt(index, 0);
        *out = nullptr;
        return Result(SHAAR_CHROMIUM_ERROR, error);
      }
    } else {
      shaar::navigation::Navigate(raw_contents, target, false);
    }
  }
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_close(
    shaar_tab* tab, shaar_error* error) {
  if (!pthread_main_np() || !tab)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = tab_handles.find(tab);
  if (found == tab_handles.end() || !LiveTab(tab))
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

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_print(
    shaar_tab* tab, shaar_error* error) {
  if (!pthread_main_np() || !tab)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = tab_handles.find(tab);
  if (found == tab_handles.end() || !LiveTab(tab))
    return Result(SHAAR_NOT_FOUND, error);
  content::WebContents* contents =
      shaar::windows_tabs::Registry().FindWebContents(tab->engine, tab->window, tab);
  Browser* browser = tab->browser;
  if (!contents || !browser ||
      browser->GetTabStripModel()->GetActiveWebContents() != contents) {
    return Result(SHAAR_NOT_READY, error);
  }
  auto* manager = PrintViewManager::FromWebContents(contents);
  if (!manager) {
    PrintViewManager::CreateForWebContents(contents);
    manager = PrintViewManager::FromWebContents(contents);
  }
  content::RenderFrameHost* main_frame = contents->GetPrimaryMainFrame();
  if (!manager || !main_frame || !manager->BasicPrint(main_frame))
    return Result(SHAAR_NOT_READY, error);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_favicon_png(
    shaar_engine* engine, shaar_scope scope, shaar_window* window,
    shaar_tab* tab, shaar_bytes* out_png, shaar_error* error) {
  if (out_png)
    *out_png = {};
  if (!pthread_main_np() || !engine || !window || !tab || !out_png ||
      scope.size < sizeof(scope) ||
      static_cast<bool>(scope.profile) ==
          static_cast<bool>(scope.private_session)) {
    return Result(SHAAR_INVALID_ARGUMENT, error);
  }
  auto found = tab_handles.find(tab);
  if (found == tab_handles.end() || !LiveTab(tab) || !LiveWindow(window) ||
      tab->engine != engine || tab->window != window) {
    return Result(SHAAR_NOT_FOUND, error);
  }
  if (tab->profile != scope.profile ||
      tab->private_session != scope.private_session) {
    return Result(scope.private_session ? SHAAR_WRONG_SESSION
                                        : SHAAR_WRONG_PROFILE, error);
  }
  content::WebContents* contents =
      shaar::windows_tabs::Registry().FindWebContents(engine, window, tab);
  if (!contents)
    return Result(SHAAR_NOT_FOUND, error);
  auto* driver = favicon::ContentFaviconDriver::FromWebContents(contents);
  if (!driver || !driver->FaviconIsValid())
    return Result(SHAAR_NOT_FOUND, error);
  scoped_refptr<base::RefCountedMemory> png =
      driver->GetFavicon().As1xPNGBytes();
  if (!png || png->size() == 0 || png->size() > 256 * 1024)
    return Result(SHAAR_NOT_FOUND, error);
  tab->favicon_png.assign(reinterpret_cast<const char*>(png->data()),
                          png->size());
  *out_png = {tab->favicon_png.data(), tab->favicon_png.size()};
  return Result(SHAAR_OK, error);
}

void CleanupTab(uint64_t serial) {
  auto found = std::find_if(tab_handles.begin(), tab_handles.end(),
                            [serial](const auto& item) {
                              return item.second->serial == serial;
                            });
  if (found == tab_handles.end())
    return;
  shaar_tab* tab = found->first;
  shaar::extensions_host::ClosePopupsForTab(tab->engine, tab);
  const std::string profile_id = tab->profile_id;
  const std::string session_id = tab->session_id;
  const std::string window_id = tab->window_id;
  const std::string tab_id = tab->tab_id;
  shaar_engine* engine = tab->engine;
  shaar_window* window = tab->window;
  tab->favicon_observation.Reset();
  tab->navigation.reset();
  tab->media.reset();
  retired_tabs.push_back(std::move(found->second));
  tab_handles.erase(found);
  static constexpr char kClosed[] = R"({"kind":"closed","schemaVersion":1})";
  shaar::EmitEvent(engine, SHAAR_EVENT_TAB,
                   {profile_id.data(), profile_id.size()},
                   {session_id.data(), session_id.size()},
                   {window_id.data(), window_id.size()},
                   {tab_id.data(), tab_id.size()},
                   {kClosed, sizeof(kClosed) - 1});
  if (shaar::windows_tabs::Registry().WindowCloseReady(engine, window))
    FinalizeWindow(window);
}
