// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/navigation/shaar_navigation_context.h"

#include <string>
#include <unordered_map>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/navigation/shaar_navigation.h"

namespace {

shaar_error_code HandleLifecycleNavigation(
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
  if (!context || !context->browser_tabs || !engine || !window || !tab ||
      !reply)
    return SHAAR_INVALID_ARGUMENT;
  if (!context->browser_tabs->FindWebContents(engine, window, tab))
    return SHAAR_NOT_FOUND;

  std::unordered_map<std::string, content::WebContents*> tabs;
  context->browser_tabs->GetTabs(engine, window, &tabs);
  const std::string tab_id(context->browser_tabs->TabID(engine, window, tab));
  std::string profile_id;
  if (scope.profile && context->profile_services)
    profile_id = context->profile_services->ProfileID(engine, scope.profile);
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
  call.bound_tabs = &tabs;
  call.scope_profile_id = profile_id.empty() ? nullptr : profile_id.c_str();
  const shaar_error_code status =
      shaar::navigation::HandleNavigation(&call, error);
  if (status != SHAAR_OK)
    return status;

  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](shaar_reply_fn callback, void* context,
             shaar_request_id request, shaar_error_code code) {
            shaar_result result = {};
            result.size = sizeof(result);
            result.request_id = request;
            result.error.size = sizeof(result.error);
            result.error.code = code;
            static constexpr char kPayload[] =
                "{\"kind\":\"navigation\",\"schemaVersion\":1}";
            result.payload_json = {kPayload, sizeof(kPayload) - 1};
            callback(context, &result);
          },
          reply, reply_context, request_id, status));
  return status;
}

}  // namespace

extern "C" void shaar_navigation_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_TAB_NAVIGATE, SHAAR_OP_TAB_NAVIGATE,
                     &HandleLifecycleNavigation);
  registry->Register(SHAAR_OP_TAB_GO, SHAAR_OP_TAB_GO,
                     &HandleLifecycleNavigation);
  registry->Register(SHAAR_OP_TAB_RELOAD, SHAAR_OP_TAB_RELOAD,
                     &HandleLifecycleNavigation);
  registry->Register(SHAAR_OP_TAB_STOP, SHAAR_OP_TAB_STOP,
                     &HandleLifecycleNavigation);
}
