// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs_handlers.h"

#include <stddef.h>

#include <algorithm>
#include <charconv>
#include <initializer_list>
#include <optional>
#include <string_view>
#include <unordered_set>
#include <vector>

#include "base/json/json_reader.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/rect.h"

namespace {

constexpr size_t kMaximumArgumentsSize = 1024 * 1024;

shaar_error_code Fail(shaar_error_code code, shaar_error* error) {
  if (error && error->size >= offsetof(shaar_error, code) + sizeof(error->code)) {
    error->code = code;
    if (error->size >=
        offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (error->size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {nullptr, 0};
  }
  return code;
}

shaar_error_code Succeed(shaar_error* error) {
  return Fail(SHAAR_OK, error);
}

shaar_error_code Complete(shaar_error_code code, shaar_error* error) {
  return code == SHAAR_OK ? Succeed(error) : Fail(code, error);
}

bool HasOneScope(const shaar_scope& scope) {
  return (scope.profile != nullptr) != (scope.private_session != nullptr);
}

std::optional<base::Value> ParseArguments(const shaar::ModuleCall* call) {
  if (!call || !call->args_json.data || !call->args_json.size ||
      call->args_json.size > kMaximumArgumentsSize)
    return std::nullopt;
  auto value = base::JSONReader::Read(
      std::string_view(call->args_json.data, call->args_json.size), 0);
  if (!value || !value->is_dict() ||
      value->GetDict().FindInt("schemaVersion") != 1)
    return std::nullopt;
  return value;
}

bool HasOnlyKeys(const base::DictValue& dict,
                 std::initializer_list<std::string_view> keys) {
  for (const auto& entry : dict) {
    if (std::find(keys.begin(), keys.end(), entry.first) == keys.end())
      return false;
  }
  return true;
}

bool ReadStringList(const base::DictValue& dict,
                    std::string_view key,
                    std::vector<std::string>* output) {
  const base::ListValue* list = dict.FindList(key);
  if (!list)
    return false;
  for (const auto& value : *list) {
    if (!value.is_string() || value.GetString().empty())
      return false;
    output->push_back(value.GetString());
  }
  return true;
}

std::optional<shaar_request_id> ReadRequestID(
    const base::DictValue& dict) {
  const std::string* text = dict.FindString("requestID");
  if (!text || text->empty() || text->size() > 20)
    return std::nullopt;
  shaar_request_id request_id = 0;
  const auto [end, error] =
      std::from_chars(text->data(), text->data() + text->size(), request_id);
  if (error != std::errc() || end != text->data() + text->size() ||
      request_id == 0)
    return std::nullopt;
  return request_id;
}

shaar_error_code ValidateCall(const shaar::ModuleCall* call,
                              shaar_operation expected,
                              bool needs_window,
                              bool needs_tab,
                              shaar_error* error) {
  if (!call || !call->engine || call->operation != expected ||
      !HasOneScope(call->scope) || (needs_window && !call->window) ||
      (needs_tab && !call->tab) || call->scope.size < sizeof(shaar_scope))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (!call->args_json.data || !call->args_json.size ||
      call->args_json.size > kMaximumArgumentsSize)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  auto value = base::JSONReader::Read(
      std::string_view(call->args_json.data, call->args_json.size), 0);
  if (!value || !value->is_dict() ||
      value->GetDict().FindInt("schemaVersion") != 1)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  return SHAAR_UNSUPPORTED_CAPABILITY;
}

}  // namespace

namespace shaar::windows_tabs {

shaar_error_code HandleWindowBindProfile(const ModuleCall* call,
                                         shaar_error* error) {
  if (call && call->scope.private_session && !call->scope.profile)
    return Fail(SHAAR_WRONG_SESSION, error);
  const shaar_error_code validation =
      ValidateCall(call, SHAAR_OP_WINDOW_BIND_PROFILE, true, false, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args || !HasOnlyKeys(args->GetDict(), {"schemaVersion", "profileID"}) ||
      !call->scope_profile_id || !call->scoped_browser ||
      !call->browsers_by_profile)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const std::string* profile_id = args->GetDict().FindString("profileID");
  if (!profile_id || profile_id->empty() || *profile_id != call->scope_profile_id)
    return Fail(SHAAR_WRONG_PROFILE, error);
  const auto [it, inserted] =
      call->browsers_by_profile->emplace(*profile_id, call->scoped_browser);
  return inserted || it->second == call->scoped_browser
             ? Succeed(error)
             : Fail(SHAAR_CONFLICT, error);
}

shaar_error_code HandleWindowSetActiveProfile(const ModuleCall* call,
                                              shaar_error* error) {
  if (call && call->scope.private_session && !call->scope.profile)
    return Fail(SHAAR_WRONG_SESSION, error);
  const shaar_error_code validation = ValidateCall(
      call, SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE, true, false, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args || !HasOnlyKeys(args->GetDict(), {"schemaVersion", "profileID"}) ||
      !call->active_browser || !call->active_profile_id ||
      !call->browsers_by_profile)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const std::string* profile_id = args->GetDict().FindString("profileID");
  if (!profile_id || profile_id->empty())
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (!call->scope_profile_id || *profile_id != call->scope_profile_id)
    return Fail(SHAAR_WRONG_PROFILE, error);
  const auto it = call->browsers_by_profile->find(*profile_id);
  if (it == call->browsers_by_profile->end())
    return Fail(SHAAR_WRONG_PROFILE, error);
  *call->active_browser = it->second;
  *call->active_profile_id = *profile_id;
  return Succeed(error);
}

shaar_error_code HandleWindowActivateTab(const ModuleCall* call,
                                         shaar_error* error) {
  const shaar_error_code validation =
      ValidateCall(call, SHAAR_OP_WINDOW_ACTIVATE_TAB, true, true, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args || !call->tab_strip_model || !call->bound_tabs)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (!HasOnlyKeys(args->GetDict(), {"schemaVersion", "tabID"}))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const std::string* tab_id = args->GetDict().FindString("tabID");
  if (!tab_id || tab_id->empty() || *tab_id != call->tab_id)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const auto it = call->bound_tabs->find(*tab_id);
  if (it == call->bound_tabs->end())
    return Fail(SHAAR_NOT_FOUND, error);
  const int index = call->tab_strip_model->GetIndexOfWebContents(it->second);
  if (index < 0)
    return Fail(SHAAR_NOT_FOUND, error);
  call->tab_strip_model->ActivateTabAt(index);
  return Succeed(error);
}

shaar_error_code HandleWindowPlaceTabs(const ModuleCall* call,
                                       shaar_error* error) {
  const shaar_error_code validation =
      ValidateCall(call, SHAAR_OP_WINDOW_PLACE_TABS, true, false, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args || !call->tab_strip_model || !call->bound_tabs)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (!HasOnlyKeys(args->GetDict(),
                   {"schemaVersion", "tabIDs", "pinnedIDs"}))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  std::vector<std::string> tab_ids;
  std::vector<std::string> pinned_ids;
  if (!ReadStringList(args->GetDict(), "tabIDs", &tab_ids) ||
      !ReadStringList(args->GetDict(), "pinnedIDs", &pinned_ids))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const std::unordered_set<std::string> requested(tab_ids.begin(), tab_ids.end());
  const std::unordered_set<std::string> pinned(pinned_ids.begin(), pinned_ids.end());
  std::vector<std::string> current_ids;
  current_ids.reserve(call->bound_tabs->size());
  for (const auto& [id, contents] : *call->bound_tabs) {
    if (id.empty() || !contents)
      return Fail(SHAAR_CONFLICT, error);
    current_ids.push_back(id);
  }
  const std::unordered_set<std::string> current(current_ids.begin(),
                                                 current_ids.end());
  if (requested.size() != tab_ids.size() || pinned.size() != pinned_ids.size())
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (requested != current)
    return Fail(SHAAR_CONFLICT, error);
  if (!ValidatePlacement(tab_ids, current_ids, pinned_ids))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  return ApplyPlacement(call->tab_strip_model, tab_ids, *call->bound_tabs,
                        pinned_ids)
             ? Succeed(error)
             : Fail(SHAAR_CONFLICT, error);
}

shaar_error_code HandleWindowRequestResolve(const ModuleCall* call,
                                            shaar_error* error) {
  const shaar_error_code validation = ValidateCall(
      call, SHAAR_OP_WINDOW_REQUEST_RESOLVE, false, false, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args ||
      !HasOnlyKeys(args->GetDict(), {"schemaVersion", "requestID", "accepted"}))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const auto request_id = ReadRequestID(args->GetDict());
  const std::optional<bool> accepted = args->GetDict().FindBool("accepted");
  if (!request_id || !accepted || (*accepted && !call->window) ||
      (!*accepted && call->window))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (!call->resolve_window_request || !call->request_registry_context)
    return Fail(SHAAR_NOT_READY, error);
  return Complete(call->resolve_window_request(
                      call->request_registry_context, *request_id, &call->scope,
                      call->window, *accepted),
                  error);
}

shaar_error_code HandleTabMove(const ModuleCall* call, shaar_error* error) {
  const shaar_error_code validation =
      ValidateCall(call, SHAAR_OP_TAB_MOVE, true, true, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args || !HasOnlyKeys(args->GetDict(), {"schemaVersion", "tabID", "toIndex"}) ||
      !call->tab_strip_model || !call->bound_tabs)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const std::string* tab_id = args->GetDict().FindString("tabID");
  const std::optional<int> to_index = args->GetDict().FindInt("toIndex");
  if (!tab_id || tab_id->empty() || *tab_id != call->tab_id || !to_index ||
      *to_index < 0 || *to_index >= call->tab_strip_model->count())
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const auto it = call->bound_tabs->find(*tab_id);
  if (it == call->bound_tabs->end())
    return Fail(SHAAR_NOT_FOUND, error);
  const int from = call->tab_strip_model->GetIndexOfWebContents(it->second);
  if (from < 0)
    return Fail(SHAAR_NOT_FOUND, error);
  const bool is_pinned = call->tab_strip_model->IsTabPinned(from);
  const bool target_is_pinned = call->tab_strip_model->IsTabPinned(*to_index);
  if (is_pinned != target_is_pinned)
    return Fail(SHAAR_CONFLICT, error);
  call->tab_strip_model->MoveWebContentsAt(from, *to_index, false);
  return Succeed(error);
}

shaar_error_code HandleTabActivationResolve(const ModuleCall* call,
                                            shaar_error* error) {
  const shaar_error_code validation = ValidateCall(
      call, SHAAR_OP_TAB_ACTIVATION_RESOLVE, true, true, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args ||
      !HasOnlyKeys(args->GetDict(), {"schemaVersion", "requestID", "accepted"}))
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const auto request_id = ReadRequestID(args->GetDict());
  const std::optional<bool> accepted = args->GetDict().FindBool("accepted");
  if (!request_id || !accepted)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  if (!call->resolve_tab_activation || !call->request_registry_context)
    return Fail(SHAAR_NOT_READY, error);
  return Complete(call->resolve_tab_activation(
                      call->request_registry_context, *request_id, &call->scope,
                      call->window, call->tab, *accepted),
                  error);
}

shaar_error_code HandleWindowSetBounds(const ModuleCall* call,
                                       shaar_error* error) {
  const shaar_error_code validation =
      ValidateCall(call, SHAAR_OP_WINDOW_SET_BOUNDS, true, false, error);
  if (validation != SHAAR_UNSUPPORTED_CAPABILITY)
    return validation;
  auto args = ParseArguments(call);
  if (!args || !HasOnlyKeys(args->GetDict(),
                            {"schemaVersion", "x", "y", "width", "height"}) ||
      !call->native_window)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  const auto& dict = args->GetDict();
  const std::optional<int> x = dict.FindInt("x");
  const std::optional<int> y = dict.FindInt("y");
  const std::optional<int> width = dict.FindInt("width");
  const std::optional<int> height = dict.FindInt("height");
  if (!x || !y || !width || !height || *width <= 0 || *height <= 0 ||
      *width > 16384 || *height > 16384 || *x < -100000 || *x > 100000 ||
      *y < -100000 || *y > 100000)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  call->native_window->SetBounds(gfx::Rect(*x, *y, *width, *height));
  return Succeed(error);
}

shaar_error_code HandleModuleOperation(const ModuleCall* call,
                                       shaar_error* error) {
  if (!call)
    return Fail(SHAAR_INVALID_ARGUMENT, error);
  switch (call->operation) {
    case SHAAR_OP_WINDOW_BIND_PROFILE:
      return HandleWindowBindProfile(call, error);
    case SHAAR_OP_WINDOW_SET_ACTIVE_PROFILE:
      return HandleWindowSetActiveProfile(call, error);
    case SHAAR_OP_WINDOW_ACTIVATE_TAB:
      return HandleWindowActivateTab(call, error);
    case SHAAR_OP_WINDOW_PLACE_TABS:
      return HandleWindowPlaceTabs(call, error);
    case SHAAR_OP_WINDOW_REQUEST_RESOLVE:
      return HandleWindowRequestResolve(call, error);
    case SHAAR_OP_TAB_MOVE:
      return HandleTabMove(call, error);
    case SHAAR_OP_TAB_ACTIVATION_RESOLVE:
      return HandleTabActivationResolve(call, error);
    case SHAAR_OP_WINDOW_SET_BOUNDS:
      return HandleWindowSetBounds(call, error);
  }
  return Fail(SHAAR_UNSUPPORTED_CAPABILITY, error);
}

}  // namespace shaar::windows_tabs
