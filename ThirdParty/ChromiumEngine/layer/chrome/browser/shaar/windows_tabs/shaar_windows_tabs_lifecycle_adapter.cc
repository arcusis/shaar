// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs_handlers.h"

#include <memory>
#include <string>
#include <unordered_map>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"

namespace {

void ReplyLater(shaar_reply_fn reply,
                void* reply_context,
                shaar_request_id request_id,
                shaar_error_code status) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](shaar_reply_fn reply, void* reply_context,
             shaar_request_id request_id, shaar_error_code status) {
            shaar_result result = {};
            result.size = sizeof(result);
            result.request_id = request_id;
            result.error.size = sizeof(result.error);
            result.error.code = status;
            static constexpr char kPayload[] =
                "{\"kind\":\"windows_tabs\",\"schemaVersion\":1}";
            result.payload_json = {kPayload, sizeof(kPayload) - 1};
            reply(reply_context, &result);
          },
          reply, reply_context, request_id, status));
}

shaar_error_code HandleLifecycleOperation(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* error) {
  if (!context || !context->browser_tabs || !engine || !window || !reply)
    return SHAAR_INVALID_ARGUMENT;
  if (tab && !context->browser_tabs->FindWebContents(engine, window, tab))
    return SHAAR_NOT_FOUND;
  std::string profile_id;
  if (scope.profile && context->profile_services) {
    profile_id = context->profile_services->ProfileID(engine, scope.profile);
  }
  auto& registry = shaar::windows_tabs::Registry();
  auto* state = registry.FindWindowState(engine, window);
  if (!state)
    return SHAAR_NOT_FOUND;
  Browser* browser = tab ? registry.FindBrowserForTab(engine, window, tab)
                         : state->browser;
  if (!tab && !profile_id.empty()) {
    auto found = state->browsers_by_profile.find(profile_id);
    browser = found == state->browsers_by_profile.end() ? nullptr
                                                        : found->second;
  }
  if (!browser || (!tab && registry.ReleaseIfClosing(browser)))
    return SHAAR_NOT_FOUND;
  std::unordered_map<std::string, content::WebContents*> tabs;
  registry.GetTabsForBrowser(engine, window, browser, &tabs);
  const std::string tab_id(context->browser_tabs->TabID(engine, window, tab));
  state = registry.EnsureWindowState(
      engine, window, browser, profile_id);
  if (!state)
    return SHAAR_NOT_READY;

  shaar::ModuleCall call = {};
  call.engine = engine;
  call.scope = scope;
  call.window = window;
  call.tab = tab;
  call.tab_id = tab_id;
  call.operation = operation;
  call.args_json = args_json;
  call.request_id = request_id;
  call.reply = reply;
  call.reply_context = reply_context;
  call.tab_strip_model = browser->GetTabStripModel();
  call.bound_tabs = &tabs;
  call.scope_profile_id = profile_id.empty() ? nullptr : profile_id.c_str();
  call.scoped_browser = browser;
  call.native_window = browser->GetWindow();
  call.active_browser = &state->active_browser;
  call.active_profile_id = &state->active_profile_id;
  call.browsers_by_profile = &state->browsers_by_profile;

  const shaar_error_code status =
      shaar::windows_tabs::HandleModuleOperation(&call, error);
  if (status == SHAAR_OK)
    ReplyLater(reply, reply_context, request_id, status);
  return status;
}

}  // namespace

extern "C" void shaar_windows_tabs_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  shaar::SetBrowserTabRegistry(&shaar::windows_tabs::Registry());
  registry->Register(SHAAR_OP_WINDOW_BIND_PROFILE,
                     SHAAR_OP_WINDOW_SET_BOUNDS,
                     &HandleLifecycleOperation);
}
