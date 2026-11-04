// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_binding.h"

#include <cmath>
#include <memory>
#include <pthread.h>
#include <unordered_map>

#include "chrome/browser/shaar/windows_tabs/shaar_page_view_host.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/web_contents.h"

namespace {
using shaar::windows_tabs::PageViewHost;

std::unordered_map<shaar_window*, std::unique_ptr<PageViewHost>>& Hosts() {
  static std::unordered_map<shaar_window*, std::unique_ptr<PageViewHost>> hosts;
  return hosts;
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
  return contents ? contents->GetNativeView() : nil;
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

extern "C" SHAAR_EXPORT shaar_error_code shaar_tab_view_attach(
    shaar_engine* engine, shaar_window* window, shaar_tab* tab,
    shaar_error* error) {
  if (!pthread_main_np())
    return Result(SHAAR_INVALID_ARGUMENT, error);
  NSView* view = FindTabView(engine, window, tab);
  if (!view)
    return Result(SHAAR_NOT_FOUND, error);
  PageViewHost* host = FindHost(window, true);
  return Result(host && host->Attach(view) ? SHAAR_OK : SHAAR_NOT_READY, error);
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
