// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/navigation/shaar_navigation.h"

#include <stddef.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace shaar::navigation {
namespace {

constexpr size_t kMaximumURLBytes = 2 * 1024 * 1024;
constexpr size_t kMaximumArgumentsBytes = 4 * 1024 * 1024;

bool IsAllowedScheme(const std::string& scheme) {
  return scheme == "http" || scheme == "https" || scheme == "file" ||
         scheme == "about";
}

bool HasOneScope(const shaar_scope& scope) {
  return (scope.profile != nullptr) != (scope.private_session != nullptr);
}

const char* ErrorMessage(shaar_error_code code, const std::string& reason) {
  if (reason == "no_back_entry") return "no_back_entry";
  if (reason == "no_forward_entry") return "no_forward_entry";
  if (reason == "scheme_blocked") return "scheme_blocked";
  if (reason == "invalid_url") return "invalid_url";
  if (reason == "unknown_argument_field") return "unknown_argument_field";
  switch (code) {
    case SHAAR_INVALID_ARGUMENT:
      return "invalid_navigation_arguments";
    case SHAAR_NOT_FOUND:
      return "navigation_tab_not_found";
    case SHAAR_POLICY_BLOCKED:
      return "navigation_policy_blocked";
    case SHAAR_CONFLICT:
      return "navigation_state_conflict";
    default:
      return "chromium_navigation_error";
  }
}

shaar_error_code Fail(shaar_error_code code, const char* message,
                      shaar_error* error) {
  if (!error) return code;
  const uint32_t supplied_size = error->size;
  if (supplied_size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  if (supplied_size >=
      offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
    error->platform_code = 0;
  if (supplied_size >= offsetof(shaar_error, message) + sizeof(error->message))
    error->message = {message, std::strlen(message)};
  return code;
}

}  // namespace

shaar_error_code ValidateURL(const std::string& input,
                             std::string* canonical_url) {
  if (!canonical_url || input.empty() || input.size() > kMaximumURLBytes ||
      std::any_of(input.begin(), input.end(),
                  [](unsigned char c) { return c <= 0x20 || c == 0x7f; })) {
    return SHAAR_INVALID_ARGUMENT;
  }

  GURL parsed(input);
  if (!parsed.is_valid() || parsed.scheme().empty())
    return SHAAR_INVALID_ARGUMENT;
  std::string scheme(parsed.scheme());
  std::transform(
      scheme.begin(), scheme.end(), scheme.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (!IsAllowedScheme(scheme)) return SHAAR_POLICY_BLOCKED;
  if ((scheme == "http" || scheme == "https") && parsed.host().empty())
    return SHAAR_INVALID_ARGUMENT;
  if (scheme == "about" && parsed.spec() != "about:blank")
    return SHAAR_POLICY_BLOCKED;

  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  *canonical_url = parsed.ReplaceComponents(replacements).spec();
  return SHAAR_OK;
}

shaar_error_code Navigate(content::WebContents* contents,
                          const std::string& url, bool user_initiated) {
  if (!contents) return SHAAR_NOT_FOUND;
  std::string canonical_url;
  const shaar_error_code validation = ValidateURL(url, &canonical_url);
  if (validation != SHAAR_OK) return validation;

  content::NavigationController::LoadURLParams params{GURL(canonical_url)};
  params.transition_type =
      user_initiated ? ui::PAGE_TRANSITION_TYPED : ui::PAGE_TRANSITION_LINK;
  params.has_user_gesture = user_initiated;
  contents->GetController().LoadURLWithParams(params);
  return SHAAR_OK;
}

shaar_error_code Go(content::NavigationController* controller, bool forward) {
  if (!controller) return SHAAR_NOT_FOUND;
  if (forward) {
    if (!controller->CanGoForward()) return SHAAR_CONFLICT;
    controller->GoForward();
  } else {
    if (!controller->CanGoBack()) return SHAAR_CONFLICT;
    controller->GoBack();
  }
  return SHAAR_OK;
}

shaar_error_code Reload(content::NavigationController* controller,
                        bool bypass_cache) {
  if (!controller) return SHAAR_NOT_FOUND;
  // During a provisional navigation, NavigationController::Reload() can
  // restart the last committed entry instead of the pending destination.
  // Reload the pending URL explicitly so a reload requested while a page is
  // loading continues toward that page.
  if (const content::NavigationEntry* pending = controller->GetPendingEntry()) {
    content::NavigationController::LoadURLParams params(pending->GetURL());
    params.transition_type = ui::PAGE_TRANSITION_RELOAD;
    params.reload_type = bypass_cache ? content::ReloadType::BYPASSING_CACHE
                                      : content::ReloadType::NORMAL;
    controller->LoadURLWithParams(params);
    return SHAAR_OK;
  }
  controller->Reload(bypass_cache ? content::ReloadType::BYPASSING_CACHE
                                  : content::ReloadType::NORMAL,
                     true);
  return SHAAR_OK;
}

shaar_error_code Stop(content::WebContents* contents) {
  if (!contents) return SHAAR_NOT_FOUND;
  contents->Stop();
  return SHAAR_OK;
}

std::string PageReadableURL(const GURL& url) {
  if (!url.is_valid()) return std::string();
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  return url.ReplaceComponents(replacements).spec();
}

shaar_error_code DecodeCommand(shaar_operation operation, shaar_bytes args_json,
                               Command* command, std::string* reason) {
  if (reason) reason->clear();
  if (!command || !args_json.data || args_json.size == 0 ||
      args_json.size > kMaximumArgumentsBytes) {
    if (reason) *reason = "invalid_arguments";
    return SHAAR_INVALID_ARGUMENT;
  }
  auto value =
      base::JSONReader::Read(std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict()) {
    if (reason) *reason = "invalid_json_object";
    return SHAAR_INVALID_ARGUMENT;
  }
  const base::DictValue& dict = value->GetDict();
  const std::optional<int> schema_version = dict.FindInt("schemaVersion");
  if (!schema_version || *schema_version != 1) {
    if (reason) *reason = "unsupported_schema_version";
    return SHAAR_INVALID_ARGUMENT;
  }

  std::vector<std::string_view> expected_keys = {"schemaVersion"};
  Command decoded;
  decoded.operation = operation;
  switch (operation) {
    case SHAAR_OP_TAB_NAVIGATE: {
      expected_keys.insert(expected_keys.end(), {"url", "userInitiated"});
      const std::string* input_url = dict.FindString("url");
      const std::optional<bool> user_initiated = dict.FindBool("userInitiated");
      if (!input_url || !user_initiated) {
        if (reason) *reason = "invalid_navigate_arguments";
        return SHAAR_INVALID_ARGUMENT;
      }
      const shaar_error_code url_result = ValidateURL(*input_url, &decoded.url);
      if (url_result != SHAAR_OK) {
        if (reason)
          *reason = url_result == SHAAR_POLICY_BLOCKED ? "scheme_blocked"
                                                       : "invalid_url";
        return url_result;
      }
      decoded.user_initiated = *user_initiated;
      break;
    }
    case SHAAR_OP_TAB_GO: {
      expected_keys.push_back("direction");
      const std::string* direction = dict.FindString("direction");
      if (!direction || (*direction != "back" && *direction != "forward")) {
        if (reason) *reason = "invalid_history_direction";
        return SHAAR_INVALID_ARGUMENT;
      }
      decoded.forward = *direction == "forward";
      break;
    }
    case SHAAR_OP_TAB_RELOAD: {
      expected_keys.push_back("mode");
      const std::string* mode = dict.FindString("mode");
      if (!mode || (*mode != "normal" && *mode != "bypass_cache")) {
        if (reason) *reason = "invalid_reload_mode";
        return SHAAR_INVALID_ARGUMENT;
      }
      decoded.bypass_cache = *mode == "bypass_cache";
      break;
    }
    case SHAAR_OP_TAB_STOP:
      break;
    default:
      if (reason) *reason = "unsupported_navigation_operation";
      return SHAAR_UNSUPPORTED_CAPABILITY;
  }

  for (const auto& entry : dict) {
    const std::string& key = entry.first;
    if (std::find(expected_keys.begin(), expected_keys.end(),
                  std::string_view(key)) == expected_keys.end()) {
      if (reason) *reason = "unknown_argument_field";
      return SHAAR_INVALID_ARGUMENT;
    }
  }
  *command = std::move(decoded);
  return SHAAR_OK;
}

shaar_error_code HandleCommand(Backend* backend, shaar_operation operation,
                               shaar_bytes args_json, std::string* reason) {
  Command command;
  const shaar_error_code decode_result =
      DecodeCommand(operation, args_json, &command, reason);
  if (decode_result != SHAAR_OK) return decode_result;
  if (!backend) {
    if (reason) *reason = "tab_not_found";
    return SHAAR_NOT_FOUND;
  }

  shaar_error_code result = SHAAR_UNSUPPORTED_CAPABILITY;
  switch (command.operation) {
    case SHAAR_OP_TAB_NAVIGATE:
      result = backend->Navigate(command.url, command.user_initiated);
      break;
    case SHAAR_OP_TAB_GO:
      result = backend->Go(command.forward);
      if (result == SHAAR_CONFLICT && reason)
        *reason = command.forward ? "no_forward_entry" : "no_back_entry";
      break;
    case SHAAR_OP_TAB_RELOAD:
      result = backend->Reload(command.bypass_cache);
      break;
    case SHAAR_OP_TAB_STOP:
      result = backend->Stop();
      break;
    default:
      return SHAAR_UNSUPPORTED_CAPABILITY;
  }
  if (result == SHAAR_CHROMIUM_ERROR && reason && reason->empty())
    *reason = "chromium_navigation_error";
  return result;
}

}  // namespace shaar::navigation

shaar_error_code shaar::navigation::HandleNavigation(
    const shaar::ModuleCall* call, shaar_error* error) {
  if (!call || !call->engine || !call->window || !call->tab ||
      !shaar::navigation::HasOneScope(call->scope) ||
      call->scope.size < sizeof(shaar_scope) || call->tab_id.empty() ||
      !call->bound_tabs) {
    return shaar::navigation::Fail(SHAAR_INVALID_ARGUMENT,
                                   "invalid_navigation_context", error);
  }
  const auto tab = call->bound_tabs->find(call->tab_id);
  if (tab == call->bound_tabs->end() || !tab->second)
    return shaar::navigation::Fail(SHAAR_NOT_FOUND, "navigation_tab_not_found",
                                   error);

  WebContentsBackend backend(tab->second);
  std::string reason;
  const shaar_error_code result =
      HandleCommand(&backend, call->operation, call->args_json, &reason);
  if (result == SHAAR_OK) return SHAAR_OK;
  return shaar::navigation::Fail(
      result, shaar::navigation::ErrorMessage(result, reason), error);
}

namespace shaar::navigation {

WebContentsBackend::WebContentsBackend(content::WebContents* contents)
    : contents_(contents) {}

shaar_error_code WebContentsBackend::Navigate(const std::string& url,
                                              bool user_initiated) {
  return shaar::navigation::Navigate(contents_, url, user_initiated);
}

shaar_error_code WebContentsBackend::Go(bool forward) {
  return contents_ ? shaar::navigation::Go(&contents_->GetController(), forward)
                   : SHAAR_NOT_FOUND;
}

shaar_error_code WebContentsBackend::Reload(bool bypass_cache) {
  return contents_ ? shaar::navigation::Reload(&contents_->GetController(),
                                               bypass_cache)
                   : SHAAR_NOT_FOUND;
}

shaar_error_code WebContentsBackend::Stop() {
  return shaar::navigation::Stop(contents_);
}

NavigationObserver::NavigationObserver(shaar_engine* engine,
                                       content::WebContents* contents,
                                       std::string profile_id,
                                       std::string session_id,
                                       std::string window_id,
                                       std::string tab_id)
    : content::WebContentsObserver(contents),
      engine_(engine),
      profile_id_(std::move(profile_id)),
      session_id_(std::move(session_id)),
      window_id_(std::move(window_id)),
      tab_id_(std::move(tab_id)) {}

NavigationObserver::~NavigationObserver() = default;

void NavigationObserver::EmitInitialState() {
  if (destroyed_ || !web_contents()) return;
  ++generation_;
  Emit("state", "", false);
}

void NavigationObserver::DidStartNavigation(content::NavigationHandle* handle) {
  if (destroyed_ || !handle || !handle->IsInPrimaryMainFrame()) return;
  active_navigation_id_ = std::to_string(handle->GetNavigationId());
  active_same_document_ = handle->IsSameDocument();
  active_navigation_failed_or_stopped_ = false;
  ++generation_;
  Emit("started", active_navigation_id_, active_same_document_, handle);
}

void NavigationObserver::DidFinishNavigation(
    content::NavigationHandle* handle) {
  if (destroyed_ || !handle || !handle->IsInPrimaryMainFrame()) return;
  const std::string navigation_id = std::to_string(handle->GetNavigationId());
  if (handle->HasCommitted()) {
    ++generation_;
    Emit("committed", navigation_id, handle->IsSameDocument(), handle);
    return;
  }
  const int error = handle->GetNetErrorCode();
  active_navigation_failed_or_stopped_ = true;
  ++generation_;
  Emit(error == net::ERR_ABORTED ? "stopped" : "failed", navigation_id,
       handle->IsSameDocument(), handle);
}

void NavigationObserver::DidStopLoading() {
  if (destroyed_) return;
  ++generation_;
  Emit(active_navigation_failed_or_stopped_ ? "state" : "finished",
       active_navigation_id_, active_same_document_);
}

void NavigationObserver::TitleWasSet(content::NavigationEntry* entry) {
  if (destroyed_ || !entry) return;
  ++generation_;
  Emit("state", active_navigation_id_, active_same_document_);
}

void NavigationObserver::PrimaryMainFrameRenderProcessGone(
    base::TerminationStatus /*status*/) {
  if (destroyed_) return;
  ++generation_;
  Emit("failed", active_navigation_id_, false, nullptr, "renderer_gone");
}

void NavigationObserver::AboutToBeDiscarded(content::WebContents* new_contents) {
  if (!new_contents || new_contents == web_contents())
    return;
  active_navigation_id_.clear();
  active_same_document_ = false;
  active_navigation_failed_or_stopped_ = false;
  Observe(new_contents);
  EmitInitialState();
}

void NavigationObserver::WebContentsDestroyed() {
  destroyed_ = true;
  Observe(nullptr);
}

void NavigationObserver::Emit(const char* phase,
                              const std::string& navigation_id,
                              bool same_document,
                              content::NavigationHandle* handle,
                              const char* failure_code) {
  content::WebContents* contents = web_contents();
  if (destroyed_ || !engine_ || !contents) return;

  base::DictValue payload;
  payload.Set("kind", "navigation");
  payload.Set("schemaVersion", 1);
  payload.Set("phase", phase);
  payload.Set("navigationID", navigation_id);
  payload.Set("generation", static_cast<double>(generation_));
  const GURL& visible_url =
      handle ? handle->GetURL() : contents->GetVisibleURL();
  const std::string readable_url = PageReadableURL(visible_url);
  if (readable_url.empty())
    payload.Set("url", base::Value());
  else
    payload.Set("url", readable_url);
  const std::u16string& title = contents->GetTitle();
  if (title.empty())
    payload.Set("title", base::Value());
  else
    payload.Set("title", base::UTF16ToUTF8(title));
  payload.Set("loading", contents->IsLoading());
  content::NavigationController& controller = contents->GetController();
  payload.Set("canGoBack", controller.CanGoBack());
  payload.Set("canGoForward", controller.CanGoForward());
  payload.Set("sameDocument", same_document);
  if (failure_code) {
    base::DictValue failure;
    failure.Set("netError", -1);
    failure.Set("isMainFrame", true);
    failure.Set("descriptionCode", failure_code);
    payload.Set("failure", std::move(failure));
  } else if (handle && handle->HasCommitted() && handle->IsErrorPage()) {
    base::DictValue failure;
    failure.Set("netError", static_cast<int>(handle->GetNetErrorCode()));
    failure.Set("isMainFrame", true);
    failure.Set("descriptionCode", "chromium_error_page");
    payload.Set("failure", std::move(failure));
  } else if (handle && !handle->HasCommitted()) {
    const int error = handle->GetNetErrorCode();
    if (error != net::OK) {
      base::DictValue failure;
      failure.Set("netError", error);
      failure.Set("isMainFrame", true);
      failure.Set("descriptionCode", error == net::ERR_ABORTED
                                         ? "cancelled"
                                         : "navigation_failed");
      payload.Set("failure", std::move(failure));
    }
  }

  std::string serialized;
  const base::Value json_value(std::move(payload));
  if (!base::JSONWriter::Write(json_value, &serialized)) return;
  const shaar_bytes profile{profile_id_.data(), profile_id_.size()};
  const shaar_bytes session{session_id_.data(), session_id_.size()};
  const shaar_bytes window{window_id_.data(), window_id_.size()};
  const shaar_bytes tab{tab_id_.data(), tab_id_.size()};
  const shaar_bytes json{serialized.data(), serialized.size()};
  shaar::EmitEvent(engine_, SHAAR_EVENT_NAVIGATION, profile, session, window,
                   tab, json);
}

}  // namespace shaar::navigation
