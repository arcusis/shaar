// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_module_registry.h"

#include <pthread.h>

#include <cstddef>
#include <cstring>
#include <iterator>
#include <memory>
#include <optional>
#include <string_view>

#include "base/json/json_reader.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"

#define SHAAR_DECLARE_OPTIONAL_MODULE(name)                 \
  extern "C" void name(ShaarModuleRegistry*) __attribute__((weak_import))
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_profiles_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_private_sessions_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_windows_tabs_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_navigation_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_downloads_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_bookmarks_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_history_register);
// BEGIN site_data
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_site_data_register);
// END site_data
// BEGIN extensions
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_extensions_register);
// END extensions
// BEGIN find
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_find_register);
// END find
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_devtools_register);
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_media_register);
// BEGIN storage_keychain
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_storage_keychain_register);
// END storage_keychain
// BEGIN tab_lifecycle
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_tab_lifecycle_register);
// END tab_lifecycle
// BEGIN save_prompts
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_save_prompts_register);
// BEGIN login
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_login_register);
// END login
SHAAR_DECLARE_OPTIONAL_MODULE(shaar_javascript_dialogs_register);
// END save_prompts
#undef SHAAR_DECLARE_OPTIONAL_MODULE

namespace {

shaar_error_code Fail(shaar_error_code code,
                      const char* message,
                      shaar_error* error) {
  if (!error)
    return code;
  const uint32_t supplied_size = error->size;
  if (supplied_size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  if (supplied_size >=
      offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
    error->platform_code = 0;
  if (supplied_size >= offsetof(shaar_error, message) + sizeof(error->message))
    error->message = {message, strlen(message)};
  return code;
}

bool ValidScope(shaar_scope scope) {
  return scope.size >= sizeof(shaar_scope) &&
         ((scope.profile != nullptr) != (scope.private_session != nullptr));
}

struct ReplyRelay {
  ShaarModuleRegistry* registry;
  shaar_engine* engine;
  shaar_request_id request_id;
  shaar_reply_fn callback;
  void* context;
};

void ForwardReply(void* context, const shaar_result* result) {
  std::unique_ptr<ReplyRelay> relay(static_cast<ReplyRelay*>(context));
  if (!result || !relay->registry->BeginCompletion(relay->request_id))
    return;
  relay->callback(relay->context, result);
  relay->registry->FinishCompletion(relay->request_id);
}

}  // namespace

bool ShaarModuleRegistry::Register(uint32_t first,
                                   uint32_t last,
                                   Handler handler,
                                   CancelHandler cancel_handler) {
  if (first == 0 || last < first || !handler)
    return false;
  auto next = ranges_.lower_bound(first);
  if (next != ranges_.end() && next->second.first <= last)
    return false;
  if (next != ranges_.begin() && std::prev(next)->second.last >= first)
    return false;
  ranges_.emplace(first, Range{first, last, handler, cancel_handler});
  return true;
}

bool ShaarModuleRegistry::RegisterModule(uint32_t module_id,
                                         const void* handlers) {
  return module_id != 0 && handlers &&
         modules_.emplace(module_id, handlers).second;
}

const void* ShaarModuleRegistry::FindModule(uint32_t module_id) const {
  auto module = modules_.find(module_id);
  return module == modules_.end() ? nullptr : module->second;
}

ShaarModuleRegistry::Handler ShaarModuleRegistry::Find(
    shaar_operation operation) const {
  const uint32_t id = static_cast<uint32_t>(operation);
  auto next = ranges_.upper_bound(id);
  if (next == ranges_.begin())
    return nullptr;
  const Range& range = std::prev(next)->second;
  return id <= range.last ? range.handler : nullptr;
}

ShaarModuleRegistry::CancelHandler ShaarModuleRegistry::FindCancel(
    shaar_operation operation) const {
  const uint32_t id = static_cast<uint32_t>(operation);
  auto next = ranges_.upper_bound(id);
  if (next == ranges_.begin())
    return nullptr;
  const Range& range = std::prev(next)->second;
  return id <= range.last ? range.cancel_handler : nullptr;
}

bool ShaarModuleRegistry::Reserve(shaar_engine* engine,
                                  shaar_request_id request_id,
                                  CancelHandler cancel_handler) {
  if (!engine || !request_id || pending_requests_.contains(request_id))
    return false;
  pending_requests_.emplace(
      request_id, PendingRequest{engine, cancel_handler, false});
  return true;
}

bool ShaarModuleRegistry::IsPending(shaar_engine* engine,
                                    shaar_request_id request_id) const {
  auto request = pending_requests_.find(request_id);
  return request != pending_requests_.end() && request->second.engine == engine &&
         !request->second.completing;
}

ShaarModuleRegistry::CancelHandler ShaarModuleRegistry::PendingCancel(
    shaar_engine* engine,
    shaar_request_id request_id) const {
  auto request = pending_requests_.find(request_id);
  if (request == pending_requests_.end() || request->second.engine != engine ||
      request->second.completing) {
    return nullptr;
  }
  return request->second.cancel_handler;
}

bool ShaarModuleRegistry::BeginCompletion(shaar_request_id request_id) {
  auto request = pending_requests_.find(request_id);
  if (request == pending_requests_.end() || request->second.completing)
    return false;
  request->second.completing = true;
  return true;
}

void ShaarModuleRegistry::FinishCompletion(shaar_request_id request_id) {
  pending_requests_.erase(request_id);
}

namespace shaar::lifecycle {

void RegisterLinkedModules(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  if (shaar_private_sessions_register)
    shaar_private_sessions_register(registry);
  if (shaar_profiles_register)
    shaar_profiles_register(registry);
  if (shaar_windows_tabs_register)
    shaar_windows_tabs_register(registry);
  if (shaar_navigation_register)
    shaar_navigation_register(registry);
  if (shaar_downloads_register)
    shaar_downloads_register(registry);
  if (shaar_bookmarks_register)
    shaar_bookmarks_register(registry);
  if (shaar_history_register)
    shaar_history_register(registry);
  // BEGIN site_data
  if (shaar_site_data_register)
    shaar_site_data_register(registry);
  // END site_data
  // BEGIN extensions
  if (shaar_extensions_register)
    shaar_extensions_register(registry);
  // END extensions
  // BEGIN find
  if (shaar_find_register)
    shaar_find_register(registry);
  // END find
  if (shaar_devtools_register)
    shaar_devtools_register(registry);
  if (shaar_media_register)
    shaar_media_register(registry);
  // BEGIN storage_keychain
  if (shaar_storage_keychain_register)
    shaar_storage_keychain_register(registry);
  // END storage_keychain
  // BEGIN tab_lifecycle
  if (shaar_tab_lifecycle_register)
    shaar_tab_lifecycle_register(registry);
  // END tab_lifecycle
  // BEGIN save_prompts
  if (shaar_save_prompts_register)
    shaar_save_prompts_register(registry);
  // BEGIN login
  if (shaar_login_register)
    shaar_login_register(registry);
  // END login
  if (shaar_javascript_dialogs_register)
    shaar_javascript_dialogs_register(registry);
  // END save_prompts
}

ShaarModuleRegistry& ModuleRegistry() {
  static ShaarModuleRegistry registry;
  static const bool registered = [] {
    RegisterLinkedModules(&registry);
    return true;
  }();
  (void)registered;
  return registry;
}

}  // namespace shaar::lifecycle

extern "C" SHAAR_EXPORT shaar_error_code shaar_submit(
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* immediate_error) {
  if (!engine || !ValidScope(scope) || !args_json.data || !args_json.size ||
      !reply || !request_id || !pthread_main_np()) {
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid submit arguments",
                immediate_error);
  }
  if (!shaar::lifecycle::EngineIsRunning(engine))
    return Fail(SHAAR_NOT_READY, "engine is not running", immediate_error);
  if (!shaar::lifecycle::EngineIsReady(engine)) {
    return Fail(shaar::lifecycle::EngineIsShuttingDown(engine)
                    ? SHAAR_SHUTTING_DOWN
                    : SHAAR_NOT_READY,
                "engine is not accepting operations", immediate_error);
  }

  const std::string_view json(args_json.data, args_json.size);
  std::optional<base::Value> parsed = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return Fail(SHAAR_INVALID_ARGUMENT, "args_json must be a JSON object",
                immediate_error);
  const base::Value* schema = parsed->GetDict().Find("schemaVersion");
  if (!schema || !schema->is_int() || schema->GetInt() != 1)
    return Fail(SHAAR_INVALID_ARGUMENT, "unsupported args_json schema",
                immediate_error);

  ShaarModuleRegistry::Handler handler =
      shaar::lifecycle::ModuleRegistry().Find(operation);
  if (!handler)
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                "no module handles this operation", immediate_error);
  ShaarModuleRegistry& registry = shaar::lifecycle::ModuleRegistry();
  const auto cancel_handler = registry.FindCancel(operation);
  if (!registry.Reserve(engine, request_id, cancel_handler))
    return Fail(SHAAR_CONFLICT, "request ID is already outstanding",
                immediate_error);
  auto* relay = new ReplyRelay{&registry, engine, request_id, reply,
                               reply_context};
  const shaar_error_code status = handler(
      &shaar::EngineContext(), engine, scope, window, tab, operation,
      args_json, request_id, &ForwardReply, relay, immediate_error);
  if (status != SHAAR_OK) {
    registry.FinishCompletion(request_id);
    // A handler returning an immediate error must not retain or call its reply.
    delete relay;
  }
  return status;
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_cancel_request(
    shaar_engine* engine,
    shaar_request_id request_id,
    shaar_error* error) {
  if (!engine || !request_id || !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid cancel arguments", error);
  ShaarModuleRegistry& registry = shaar::lifecycle::ModuleRegistry();
  if (!registry.IsPending(engine, request_id))
    return Fail(SHAAR_NOT_FOUND, "request is not outstanding", error);
  // Cancel handlers are associated with the owning module's range. Store the
  // function in the pending request when reserving so the caller need not guess
  // the module from a request ID.
  auto cancel = registry.PendingCancel(engine, request_id);
  if (!cancel)
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                "request owner does not support cancellation", error);
  return cancel(engine, request_id, error);
}
