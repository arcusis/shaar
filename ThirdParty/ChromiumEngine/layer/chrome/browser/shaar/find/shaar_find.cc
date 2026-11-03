// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/find/shaar_find.h"

#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "base/strings/utf_string_conversions.h"

namespace {

constexpr char kFindStateKey[] = "shaar.find.state";
constexpr size_t kMaximumQueryBytes = 4096;

void ReplyLater(shaar_reply_fn reply, void* context, shaar_request_id id,
                shaar_error_code code) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](shaar_reply_fn callback, void* callback_context,
                        shaar_request_id request, shaar_error_code status) {
                       shaar_result result = {};
                       result.size = sizeof(result);
                       result.request_id = request;
                       result.error.size = sizeof(result.error);
                       result.error.code = status;
                       static constexpr char kPayload[] =
                           "{\"kind\":\"find\",\"schemaVersion\":1}";
                       result.payload_json = {kPayload, sizeof(kPayload) - 1};
                       callback(callback_context, &result);
                     }, reply, context, id, code));
}

class FindState final : public base::SupportsUserData::Data,
                        public find_in_page::FindResultObserver,
                        public content::WebContentsObserver {
 public:
  FindState(content::WebContents* contents, shaar_engine* engine,
            std::string profile_id, std::string session_id,
            std::string window_id, std::string tab_id)
      : content::WebContentsObserver(contents),
        engine_(engine),
        profile_id_(std::move(profile_id)),
        session_id_(std::move(session_id)),
        window_id_(std::move(window_id)),
        tab_id_(std::move(tab_id)),
        helper_(find_in_page::FindTabHelper::FromWebContents(contents)) {
    helper_->AddObserver(this);
  }

  ~FindState() override {
    if (helper_)
      helper_->RemoveObserver(this);
  }

  void SetRequest(shaar_request_id request) { request_id_ = request; }

  void OnFindResultAvailable(content::WebContents*) override {
    if (!helper_ || !request_id_)
      return;
    const auto& update = helper_->find_result();
    if (update.request_id() != chromium_request_id_)
      return;
    base::Value::Dict payload;
    payload.Set("kind", "result");
    payload.Set("schemaVersion", 1);
    payload.Set("requestID", std::to_string(request_id_));
    payload.Set("matchCount", update.number_of_matches());
    payload.Set("activeMatch", update.active_match_ordinal());
    payload.Set("final", update.final_update());
    std::string json;
    if (!base::JSONWriter::Write(payload, &json))
      return;
    shaar::EmitEvent(engine_, SHAAR_EVENT_FIND,
                     {profile_id_.data(), profile_id_.size()},
                     {session_id_.data(), session_id_.size()},
                     {window_id_.data(), window_id_.size()},
                     {tab_id_.data(), tab_id_.size()},
                     {json.data(), json.size()});
  }

  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override {
    if (helper_ == helper)
      helper_ = nullptr;
    request_id_ = 0;
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame()) {
      request_id_ = 0;
      if (helper_)
        helper_->StopFinding(find_in_page::SelectionAction::kKeep);
    }
  }

  find_in_page::FindTabHelper* helper() const { return helper_; }
  void SetChromiumRequest(int request) { chromium_request_id_ = request; }

 private:
  shaar_engine* const engine_;
  const std::string profile_id_;
  const std::string session_id_;
  const std::string window_id_;
  const std::string tab_id_;
  raw_ptr<find_in_page::FindTabHelper> helper_;
  shaar_request_id request_id_ = 0;
  int chromium_request_id_ = 0;
};

struct FindArguments {
  std::string query;
  bool forward = true;
  find_in_page::SelectionAction selection =
      find_in_page::SelectionAction::kKeep;
};

bool ParseArguments(shaar_operation operation, shaar_bytes bytes,
                    FindArguments* out) {
  if (!out || (bytes.size && !bytes.data))
    return false;
  auto value = base::JSONReader::Read(
      std::string_view(bytes.data ? bytes.data : "", bytes.size));
  if (!value || !value->is_dict())
    return false;
  const base::Value::Dict& dict = value->GetDict();
  const std::optional<int> version = dict.FindInt("schemaVersion");
  if (!version || *version != 1)
    return false;
  if (operation == SHAAR_OP_TAB_FIND) {
    const std::string* query = dict.FindString("query");
    const std::optional<bool> forward = dict.FindBool("forward");
    if (!query || !forward || query->size() > kMaximumQueryBytes ||
        dict.size() != 3)
      return false;
    out->query = *query;
    out->forward = *forward;
    return true;
  }
  const std::string* selection = dict.FindString("selection");
  if (!selection || dict.size() != 2)
    return false;
  if (*selection == "keep")
    out->selection = find_in_page::SelectionAction::kKeep;
  else if (*selection == "clear")
    out->selection = find_in_page::SelectionAction::kClear;
  else
    return false;
  return true;
}

}  // namespace

shaar_error_code HandleFindOperation(
    shaar::ShaarEngineContext* context, shaar_engine* engine,
    shaar_scope scope, shaar_window* window, shaar_tab* tab,
    shaar_operation operation, shaar_bytes args_json,
    shaar_request_id request_id, shaar_reply_fn reply, void* reply_context,
    shaar_error*) {
  if (!context || !context->browser_tabs || !engine || !window || !tab ||
      !reply || !request_id)
    return SHAAR_INVALID_ARGUMENT;
  if (operation != SHAAR_OP_TAB_FIND && operation != SHAAR_OP_TAB_STOP_FIND)
    return SHAAR_INVALID_ARGUMENT;
  FindArguments args;
  if (!ParseArguments(operation, args_json, &args))
    return SHAAR_INVALID_ARGUMENT;
  content::WebContents* contents =
      context->browser_tabs->FindWebContents(engine, window, tab);
  if (!contents)
    return SHAAR_NOT_FOUND;
  Browser* browser = context->browser_tabs->FindBrowser(engine, window);
  if (!browser)
    return SHAAR_NOT_FOUND;
  if (browser->tab_strip_model()->GetActiveWebContents() != contents)
    return SHAAR_CONFLICT;

  Profile* expected_profile = nullptr;
  std::string_view profile_id;
  std::string_view session_id;
  if (scope.profile && !scope.private_session) {
    if (!context->profile_services)
      return SHAAR_NOT_READY;
    expected_profile = context->profile_services->ResolveProfile(engine,
                                                                  scope.profile);
    profile_id = context->profile_services->ProfileID(engine, scope.profile);
    if (!expected_profile || profile_id.empty())
      return SHAAR_NOT_FOUND;
    if (contents->GetBrowserContext() != expected_profile)
      return SHAAR_WRONG_PROFILE;
  } else if (scope.private_session && !scope.profile) {
    if (!context->private_sessions)
      return SHAAR_NOT_READY;
    Profile* otr = nullptr;
    if (!context->private_sessions->Resolve(
            engine, scope.private_session, &expected_profile, &otr,
            &profile_id, &session_id))
      return SHAAR_WRONG_SESSION;
    if (!otr || profile_id.empty() || session_id.empty())
      return SHAAR_NOT_FOUND;
    if (contents->GetBrowserContext() != otr)
      return SHAAR_WRONG_SESSION;
  } else {
    return SHAAR_INVALID_ARGUMENT;
  }

  const std::string window_id;
  const std::string tab_id(context->browser_tabs->TabID(engine, window, tab));
  if (tab_id.empty())
    return SHAAR_NOT_FOUND;
  auto* state = static_cast<FindState*>(contents->GetUserData(
      reinterpret_cast<const void*>(kFindStateKey)));
  auto* helper = find_in_page::FindTabHelper::FromWebContents(contents);
  if (!helper) {
    find_in_page::FindTabHelper::CreateForWebContents(contents);
    helper = find_in_page::FindTabHelper::FromWebContents(contents);
  }
  if (!helper)
    return SHAAR_NOT_READY;
  if (!state) {
    contents->SetUserData(
        reinterpret_cast<const void*>(kFindStateKey),
        std::make_unique<FindState>(contents, engine, std::string(profile_id),
                                    std::string(session_id), window_id,
                                    tab_id));
    state = static_cast<FindState*>(contents->GetUserData(
        reinterpret_cast<const void*>(kFindStateKey)));
  }

  if (operation == SHAAR_OP_TAB_FIND) {
    state->SetRequest(request_id);
    if (args.query.empty()) {
      state->SetRequest(0);
      helper->StopFinding(find_in_page::SelectionAction::kClear);
    } else {
      helper->StartFinding(base::UTF8ToUTF16(args.query), args.forward,
                           /*case_sensitive=*/false, /*find_match=*/true);
      state->SetChromiumRequest(helper->current_find_request_id());
    }
  } else {
    state->SetRequest(0);
    helper->StopFinding(args.selection);
  }
  ReplyLater(reply, reply_context, request_id, SHAAR_OK);
  return SHAAR_OK;
}
