// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_binding.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <pthread.h>
#include <unordered_map>

#include "base/no_destructor.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/contents_container_view.h"
#include "chrome/browser/ui/views/frame/contents_web_view.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"

namespace {
using shaar::windows_tabs::PageViewHost;

std::unordered_map<shaar_window*, std::unique_ptr<PageViewHost>>& Hosts() {
  // Chromium can exit directly after closing its browsers. Any host still
  // retained by the app then outlives AppKit's shutdown; its destructor must
  // not message a tab view from the C runtime's static destruction pass.
  static base::NoDestructor<
      std::unordered_map<shaar_window*, std::unique_ptr<PageViewHost>>>
      hosts;
  return *hosts;
}

PageViewHost* FindHost(shaar_window* window, bool create) {
  if (!window || !pthread_main_np() ||
      !shaar::windows_tabs::Registry().FindWindowOwner(window))
    return nullptr;
  auto& hosts = Hosts();
  auto found = hosts.find(window);
  if (found != hosts.end())
    return found->second.get();
  if (!create)
    return nullptr;
  auto host = std::make_unique<PageViewHost>(NSMakeRect(0, 0, 1200, 780));
  PageViewHost* result = host.get();
  hosts.emplace(window, std::move(host));
  return result;
}

NSView* FindTabView(shaar_engine* engine,
                    shaar_window* window,
                    shaar_tab* tab) {
  if (!engine || !window || !tab ||
      shaar::windows_tabs::Registry().FindWindowOwner(window) != engine ||
      shaar::windows_tabs::Registry().FindTabWindow(tab) != window)
    return nil;
  content::WebContents* contents =
      shaar::windows_tabs::Registry().FindWebContents(engine, window, tab);
  return contents ? contents->GetNativeView().GetNativeNSView() : nil;
}

// Moving an NSView alone leaves Chromium's WebView owning its compositor.
// Release that presentation before Shaar borrows the view, while retaining its
// existing Swift/AppKit container if it has already been placed in our window.
void DetachChromePresentation(Browser* browser, content::WebContents* contents,
                             PageViewHost* host) {
  if (!browser || !contents || !host)
    return;
  BrowserView* browser_view = BrowserView::GetBrowserViewForBrowser(browser);
  ContentsContainerView* container =
      browser_view ? browser_view->GetContentsContainerViewFor(contents)
                   : nullptr;
  ContentsWebView* contents_view = container ? container->contents_view() : nullptr;
  if (!contents_view || contents_view->web_contents() != contents)
    return;
  NSView* native_view = contents->GetNativeView().GetNativeNSView();
  NSView* parent = native_view.window == host->window()
                       ? native_view.superview : nil;
  const NSRect frame = native_view.frame;
  contents_view->SetWebContents(nullptr);
  if (parent) {
    [parent addSubview:native_view];
    native_view.frame = frame;
  }
}

shaar_error_code Result(shaar_error_code status, shaar_error* error) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = status;
    if (size >= offsetof(shaar_error, platform_code) +
                    sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {};
  }
  return status;
}

}  // namespace

namespace shaar::windows_tabs {
bool HasNeverShownPageHost(shaar_window* window,
                           content::WebContents* contents) {
  PageViewHost* host = FindHost(window, false);
  return host && contents && host->NeverShown() &&
         host->selected_view() == contents->GetNativeView().GetNativeNSView();
}

void ShowSelectedWebContents(content::WebContents* previous,
                             content::WebContents* selected) {
  if (previous && previous != selected)
    previous->UpdateWebContentsVisibility(content::Visibility::HIDDEN);
  if (selected) {
    NSWindow* window = selected->GetNativeView().GetNativeNSView().window;
    content::Visibility visibility = content::Visibility::VISIBLE;
    if (window && (!window.isVisible || window.isMiniaturized)) {
      visibility = content::Visibility::HIDDEN;
    } else if (window &&
               !(window.occlusionState & NSWindowOcclusionStateVisible)) {
      visibility = content::Visibility::OCCLUDED;
    }
    selected->UpdateWebContentsVisibility(visibility);
  }
}

void ActivatePageHost(shaar_window* window, Browser* browser,
                      content::WebContents* previous,
                      content::WebContents* selected) {
  if (PageViewHost* host = FindHost(window, false)) {
    DetachChromePresentation(browser, selected, host);
    host->Attach(selected->GetNativeView().GetNativeNSView());
    host->SetSelectedWebContents(selected);
  } else {
    ShowSelectedWebContents(previous, selected);
  }
}

void ReleasePageHost(shaar_window* window) {
  if (pthread_main_np())
    Hosts().erase(window);
}
}  // namespace shaar::windows_tabs

extern "C" SHAAR_EXPORT void* shaar_window_host_view(shaar_window* window) {
  PageViewHost* host = FindHost(window, true);
  return host ? (__bridge void*)host->view() : nullptr;
}

extern "C" SHAAR_EXPORT void* shaar_window_native_window(
    shaar_window* window) {
  PageViewHost* host = FindHost(window, true);
  return host ? (__bridge void*)host->window() : nullptr;
}

extern "C" SHAAR_EXPORT void* shaar_tab_host_view(shaar_tab* tab) {
  if (!pthread_main_np())
    return nullptr;
  shaar_window* window = shaar::windows_tabs::Registry().FindTabWindow(tab);
  shaar_engine* engine =
      shaar::windows_tabs::Registry().FindWindowOwner(window);
  NSView* view = FindTabView(engine, window, tab);
  return (__bridge void*)view;
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_get_probe_state(
    shaar_engine* engine, shaar_scope scope, shaar_window* window, shaar_tab* tab,
    shaar_tab_probe_state* out, shaar_error* error) {
  if (!pthread_main_np() || !out || out->size < sizeof(*out) ||
      scope.size < sizeof(scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr)))
    return Result(SHAAR_INVALID_ARGUMENT, error);
  out->live_web_contents = 0;
  out->selected_native_tab = 0;
  out->displayed_native_web_contents = 0;
  out->context_is_private = 0;
  out->scope_owns_tab = 0;
  if (!engine || !window || !tab ||
      shaar::windows_tabs::Registry().FindWindowOwner(window) != engine ||
      shaar::windows_tabs::Registry().FindTabWindow(tab) != window)
    return Result(SHAAR_NOT_FOUND, error);
  content::WebContents* contents =
      shaar::windows_tabs::Registry().FindWebContents(engine, window, tab);
  Browser* browser =
      shaar::windows_tabs::Registry().FindBrowserForTab(engine, window, tab);
  auto* window_state =
      shaar::windows_tabs::Registry().FindWindowState(engine, window);
  PageViewHost* host = FindHost(window, false);
  NSView* native_view = contents
                            ? contents->GetNativeView().GetNativeNSView()
                            : nil;
  out->live_web_contents = contents != nullptr;
  out->selected_native_tab =
      contents && browser && window_state &&
      window_state->active_browser == browser &&
      browser->tab_strip_model()->GetActiveWebContents() == contents;
  out->displayed_native_web_contents =
      native_view && host && host->selected_view() == native_view &&
      native_view.window == host->window() &&
      !native_view.isHiddenOrHasHiddenAncestor;
  out->context_is_private = contents &&
      contents->GetBrowserContext()->IsOffTheRecord();
  auto& context = shaar::EngineContext();
  Profile* expected_profile = nullptr;
  if (scope.profile && context.profile_services) {
    expected_profile =
        context.profile_services->ResolveProfile(engine, scope.profile);
  } else if (scope.private_session && context.private_sessions) {
    Profile* parent = nullptr;
    std::string_view profile_id;
    std::string_view session_id;
    context.private_sessions->Resolve(engine, scope.private_session,
                                      &parent, &expected_profile,
                                      &profile_id, &session_id);
  }
  out->scope_owns_tab = expected_profile && contents &&
      contents->GetBrowserContext() == expected_profile;
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT void *shaar_devtools_frontend_view(shaar_engine *engine,
                                                           shaar_scope scope,
                                                           shaar_window *window,
                                                           shaar_tab *tab) {
  if (!pthread_main_np() || !engine || !window || !tab ||
      scope.size < sizeof(shaar_scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr)))
    return nullptr;
  auto &context = shaar::EngineContext();
  content::WebContents *inspected =
      shaar::windows_tabs::Registry().FindWebContents(engine, window, tab);
  if (!inspected)
    return nullptr;
  Profile *expected = nullptr;
  if (scope.profile && context.profile_services) {
    expected = context.profile_services->ResolveProfile(engine, scope.profile);
  } else if (scope.private_session && context.private_sessions) {
    Profile *parent = nullptr;
    std::string_view profile_id;
    std::string_view session_id;
    if (!context.private_sessions->Resolve(engine, scope.private_session,
                                           &parent, &expected, &profile_id,
                                           &session_id))
      return nullptr;
  }
  if (!expected || inspected->GetBrowserContext() != expected)
    return nullptr;
  content::WebContents *frontend =
      DevToolsWindow::GetInTabWebContents(inspected, nullptr);
  return frontend ? (__bridge void *)frontend->GetNativeView().GetNativeNSView()
                  : nullptr;
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_devtools_geometry(
    shaar_engine* engine, shaar_scope scope, shaar_window* window,
    shaar_tab* tab, shaar_devtools_geometry* out, shaar_error* error) {
  if (!pthread_main_np() || !out || out->size < sizeof(*out) ||
      !std::getenv("SHAAR_ENGINE_TESTING") ||
      std::strcmp(std::getenv("SHAAR_ENGINE_TESTING"), "1") != 0)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  out->container_width = 0;
  out->inspected_page_right = 0;
  out->frontend_placeholder_right = 0;
  out->frontend_width = 0;
  if (!shaar_devtools_frontend_view(engine, scope, window, tab))
    return Result(SHAAR_NOT_READY, error);
  PageViewHost* host = FindHost(window, false);
  if (!host || host->selected_view() != FindTabView(engine, window, tab) ||
      !host->GetDevToolsGeometry(out))
    return Result(SHAAR_NOT_READY, error);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_view_attach(
    shaar_engine* engine, shaar_window* window, shaar_tab* tab,
    shaar_error* error) {
  if (!pthread_main_np())
    return Result(SHAAR_INVALID_ARGUMENT, error);
  NSView* view = FindTabView(engine, window, tab);
  if (!view)
    return Result(SHAAR_NOT_FOUND, error);
  PageViewHost* host = FindHost(window, true);
  if (!host)
    return Result(SHAAR_NOT_READY, error);
  content::WebContents* contents =
      shaar::windows_tabs::Registry().FindWebContents(engine, window, tab);
  Browser* browser =
      shaar::windows_tabs::Registry().FindBrowserForTab(engine, window, tab);
  DetachChromePresentation(browser, contents, host);
  if (!host->Attach(view))
    return Result(SHAAR_NOT_READY, error);
  host->SetSelectedWebContents(contents);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_view_detach(
    shaar_engine* engine, shaar_window* window, shaar_tab* tab,
    shaar_error* error) {
  if (!pthread_main_np())
    return Result(SHAAR_INVALID_ARGUMENT, error);
  NSView* view = FindTabView(engine, window, tab);
  if (!view)
    return Result(SHAAR_NOT_FOUND, error);
  PageViewHost* host = FindHost(window, false);
  if (host)
    host->Detach(view);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_view_focus(
    shaar_engine* engine, shaar_window* window, shaar_tab* tab,
    shaar_error* error) {
  if (!pthread_main_np())
    return Result(SHAAR_INVALID_ARGUMENT, error);
  NSView* view = FindTabView(engine, window, tab);
  if (!view)
    return Result(SHAAR_NOT_FOUND, error);
  PageViewHost* host = FindHost(window, false);
  return Result(host && host->Focus(view) ? SHAAR_OK : SHAAR_CONFLICT, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_window_host_resize(
    shaar_engine* engine, shaar_window* window, double width, double height,
    shaar_error* error) {
  if (!pthread_main_np() || !std::isfinite(width) || !std::isfinite(height) ||
      width < 0 || height < 0)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  if (shaar::windows_tabs::Registry().FindWindowOwner(window) != engine ||
      !engine)
    return Result(SHAAR_NOT_FOUND, error);
  PageViewHost* host = FindHost(window, true);
  if (!host)
    return Result(SHAAR_NOT_READY, error);
  host->Resize(NSMakeSize(width, height));
  return Result(SHAAR_OK, error);
}
