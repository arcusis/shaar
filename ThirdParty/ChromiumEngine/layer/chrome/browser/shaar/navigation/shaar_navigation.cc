// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/navigation/shaar_navigation.h"

#include <algorithm>
#include <cctype>

#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "url/gurl.h"

namespace shaar::navigation {
namespace {

constexpr size_t kMaximumURLBytes = 2 * 1024 * 1024;

bool IsAllowedScheme(const std::string& scheme) {
  return scheme == "http" || scheme == "https" || scheme == "file" ||
         scheme == "about";
}

}  // namespace

shaar_error_code ValidateURL(const std::string& input,
                             std::string* canonical_url) {
  if (!canonical_url || input.empty() || input.size() > kMaximumURLBytes ||
      std::any_of(input.begin(), input.end(), [](unsigned char c) {
        return c <= 0x20 || c == 0x7f;
      })) {
    return SHAAR_INVALID_ARGUMENT;
  }

  GURL parsed(input);
  if (!parsed.is_valid() || parsed.scheme().empty())
    return SHAAR_INVALID_ARGUMENT;
  std::string scheme = parsed.scheme();
  std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (!IsAllowedScheme(scheme))
    return SHAAR_POLICY_BLOCKED;
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
                          const std::string& url,
                          bool user_initiated) {
  if (!contents)
    return SHAAR_NOT_FOUND;
  std::string canonical_url;
  const shaar_error_code validation = ValidateURL(url, &canonical_url);
  if (validation != SHAAR_OK)
    return validation;

  content::NavigationController::LoadURLParams params{GURL(canonical_url)};
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  params.has_user_gesture = user_initiated;
  contents->GetController().LoadURLWithParams(params);
  return SHAAR_OK;
}

shaar_error_code Go(content::NavigationController* controller, bool forward) {
  if (!controller)
    return SHAAR_NOT_FOUND;
  if (forward) {
    if (!controller->CanGoForward())
      return SHAAR_CONFLICT;
    controller->GoForward();
  } else {
    if (!controller->CanGoBack())
      return SHAAR_CONFLICT;
    controller->GoBack();
  }
  return SHAAR_OK;
}

shaar_error_code Reload(content::NavigationController* controller,
                        bool bypass_cache) {
  if (!controller)
    return SHAAR_NOT_FOUND;
  controller->Reload(bypass_cache ? content::ReloadType::BYPASSING_CACHE
                                  : content::ReloadType::NORMAL,
                     true);
  return SHAAR_OK;
}

shaar_error_code Stop(content::WebContents* contents) {
  if (!contents)
    return SHAAR_NOT_FOUND;
  contents->Stop();
  return SHAAR_OK;
}

std::string PageReadableURL(const GURL& url) {
  if (!url.is_valid())
    return std::string();
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  return url.ReplaceComponents(replacements).spec();
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
  if (destroyed_ || !web_contents())
    return;
  Emit("state", "", false);
}

void NavigationObserver::DidStartNavigation(content::NavigationHandle* handle) {
  if (destroyed_ || !handle || !handle->IsInPrimaryMainFrame())
    return;
  active_navigation_id_ = std::to_string(handle->GetNavigationId());
  ++generation_;
  Emit("started", active_navigation_id_, handle->IsSameDocument(), handle);
}

void NavigationObserver::DidFinishNavigation(content::NavigationHandle* handle) {
  if (destroyed_ || !handle || !handle->IsInPrimaryMainFrame())
    return;
  const std::string navigation_id = std::to_string(handle->GetNavigationId());
  if (handle->HasCommitted()) {
    ++generation_;
    Emit("committed", navigation_id, handle->IsSameDocument(), handle);
    return;
  }
  const int error = handle->GetNetErrorCode();
  ++generation_;
  Emit(error == net::ERR_ABORTED ? "stopped" : "failed", navigation_id,
       handle->IsSameDocument(), handle);
}

void NavigationObserver::DidStopLoading() {
  if (destroyed_)
    return;
  ++generation_;
  Emit("finished", active_navigation_id_, false);
}

void NavigationObserver::TitleWasSet(content::NavigationEntry* entry) {
  if (destroyed_ || !entry)
    return;
  ++generation_;
  Emit("state", active_navigation_id_, false);
}

void NavigationObserver::WebContentsDestroyed() {
  destroyed_ = true;
  Observe(nullptr);
}

void NavigationObserver::Emit(const char* phase,
                              const std::string& navigation_id,
                              bool same_document,
                              content::NavigationHandle* handle) {
  content::WebContents* contents = web_contents();
  if (destroyed_ || !engine_ || !contents)
    return;

  base::Value::Dict payload;
  payload.Set("kind", "navigation");
  payload.Set("schemaVersion", 1);
  payload.Set("phase", phase);
  payload.Set("navigationID", navigation_id);
  payload.Set("generation", static_cast<int64_t>(generation_));
  const GURL& visible_url = handle ? handle->GetURL() : contents->GetVisibleURL();
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
  if (handle && handle->HasCommitted() && handle->IsErrorPage()) {
    base::Value::Dict failure;
    failure.Set("netError", static_cast<int>(handle->GetNetErrorCode()));
    failure.Set("isMainFrame", true);
    failure.Set("descriptionCode", "chromium_error_page");
    payload.Set("failure", std::move(failure));
  } else if (handle && !handle->HasCommitted()) {
    const int error = handle->GetNetErrorCode();
    if (error != net::OK) {
      base::Value::Dict failure;
      failure.Set("netError", error);
      failure.Set("isMainFrame", true);
      failure.Set("descriptionCode", error == net::ERR_ABORTED ? "cancelled"
                                                                 : "navigation_failed");
      payload.Set("failure", std::move(failure));
    }
  }

  std::string serialized;
  if (!base::JSONWriter::Write(base::Value(std::move(payload)), &serialized))
    return;
  const shaar_bytes profile{profile_id_.data(), profile_id_.size()};
  const shaar_bytes session{session_id_.data(), session_id_.size()};
  const shaar_bytes window{window_id_.data(), window_id_.size()};
  const shaar_bytes tab{tab_id_.data(), tab_id_.size()};
  const shaar_bytes json{serialized.data(), serialized.size()};
  shaar::EmitEvent(engine_, SHAAR_EVENT_NAVIGATION, profile, session, window, tab, json);
}

}  // namespace shaar::navigation
