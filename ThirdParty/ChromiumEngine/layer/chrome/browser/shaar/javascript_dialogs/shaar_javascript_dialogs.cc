// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/javascript_dialogs/shaar_javascript_dialogs.h"

#include <map>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/strings/utf_string_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/web_contents.h"

namespace shaar::javascript_dialogs {
namespace {

struct PendingDialog {
  shaar_engine* engine;
  content::WebContents* contents;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  content::JavaScriptDialogManager::DialogClosedCallback callback;
  content::JavaScriptDialogType type;
};

std::map<std::string, PendingDialog>& Pending() {
  static base::NoDestructor<std::map<std::string, PendingDialog>> pending;
  return *pending;
}

void Expire(std::string id);

bool IsActiveOwnedTab(shaar_engine* engine, content::WebContents* contents,
                      windows_tabs::SelectedRegularTab* identity) {
  auto selected = windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  const bool regular_profile = contents && contents->GetBrowserContext() &&
      !contents->GetBrowserContext()->IsOffTheRecord();
  if (!DialogMayBePresented(selected.has_value(), regular_profile))
    return false;
  *identity = std::move(*selected);
  return true;
}

bool Start(shaar_engine* engine, content::WebContents* contents,
           content::JavaScriptDialogType type, const std::u16string& message,
           const std::u16string& default_prompt, bool before_unload,
           content::JavaScriptDialogManager::DialogClosedCallback* callback) {
  windows_tabs::SelectedRegularTab identity{};
  if (!callback || callback->is_null() || !lifecycle::EngineIsReady(engine) || !contents ||
      !IsActiveOwnedTab(engine, contents, &identity) || Pending().size() >= 8)
    return false;
  const std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  base::Value::Dict payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "javascriptDialogRequested");
  payload.Set("id", id);
  payload.Set("dialogType", before_unload ? "beforeUnload" :
      type == content::JAVASCRIPT_DIALOG_TYPE_ALERT ? "alert" :
      type == content::JAVASCRIPT_DIALOG_TYPE_CONFIRM ? "confirm" : "prompt");
  payload.Set("pageURL", contents->GetLastCommittedURL().spec());
  payload.Set("origin", contents->GetLastCommittedURL().GetOrigin().spec());
  payload.Set("message", before_unload ? "" : base::UTF16ToUTF8(message));
  payload.Set("defaultPrompt", before_unload ? "" : base::UTF16ToUTF8(default_prompt));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return false;
  auto [it, inserted] = Pending().emplace(
      id, PendingDialog{engine, contents, identity.profile_id, identity.window_id, identity.tab_id,
                        std::move(*callback), type});
  if (!inserted)
    return false;
  const auto emitted = EmitEvent(
      engine, SHAAR_EVENT_JAVASCRIPT_DIALOG,
      {identity.profile_id.data(), identity.profile_id.size()}, {},
      {identity.window_id.data(), identity.window_id.size()},
      {identity.tab_id.data(), identity.tab_id.size()}, {json.data(), json.size()});
  if (emitted != SHAAR_OK) {
    auto callback = std::move(it->second.callback);
    Pending().erase(it);
    std::move(callback).Run(false, {});
    return true;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&Expire, id), base::Minutes(2));
  return true;
}

void Finish(const std::string& id, bool accepted, std::u16string input) {
  auto it = Pending().find(id);
  if (it == Pending().end())
    return;
  auto callback = std::move(it->second.callback);
  Pending().erase(it);
  std::move(callback).Run(accepted, input);
}

void EmitDismiss(const std::string& id, const PendingDialog& pending) {
  if (!lifecycle::EngineIsReady(pending.engine))
    return;
  base::Value::Dict payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "javascriptDialogDismissed");
  payload.Set("id", id);
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return;
  EmitEvent(pending.engine, SHAAR_EVENT_JAVASCRIPT_DIALOG,
            {pending.profile_id.data(), pending.profile_id.size()}, {},
            {pending.window_id.data(), pending.window_id.size()},
            {pending.tab_id.data(), pending.tab_id.size()},
            {json.data(), json.size()});
}

void Expire(std::string id) {
  auto it = Pending().find(id);
  if (it == Pending().end())
    return;
  EmitDismiss(id, it->second);
  Finish(id, SuppressedDialogAccepted(it->second.type), {});
}

void ReplyLater(shaar_request_id request_id, shaar_reply_fn reply,
                void* reply_context) {
  shaar_result result{};
  result.size = sizeof(result);
  result.request_id = request_id;
  result.error.size = sizeof(result.error);
  result.error.code = SHAAR_OK;
  reply(reply_context, &result);
}

shaar_error_code Fail(shaar_error* error, shaar_error_code code) {
  if (error && error->size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  return code;
}

}  // namespace

bool DialogMayBePresented(bool is_selected_tab, bool is_regular_profile) {
  return is_selected_tab && is_regular_profile;
}

bool SuppressedDialogAccepted(content::JavaScriptDialogType type) {
  return type == content::JAVASCRIPT_DIALOG_TYPE_ALERT;
}

Manager::Manager() = default;
Manager::~Manager() = default;

void Manager::RunJavaScriptDialog(
    content::WebContents* web_contents,
    content::RenderFrameHost* render_frame_host,
    content::JavaScriptDialogType dialog_type,
    const std::u16string& message_text,
    const std::u16string& default_prompt_text,
    DialogClosedCallback callback,
    bool* did_suppress_message) {
  *did_suppress_message = false;
  (void)render_frame_host;
  if (!Start(lifecycle::ActiveEngine(), web_contents, dialog_type, message_text,
             default_prompt_text, false, &callback)) {
    std::move(callback).Run(SuppressedDialogAccepted(dialog_type), {});
  }
}

void Manager::RunBeforeUnloadDialog(content::WebContents* web_contents,
                                    content::RenderFrameHost* render_frame_host,
                                    bool is_reload,
                                    DialogClosedCallback callback) {
  (void)render_frame_host;
  (void)is_reload;
  if (!Start(lifecycle::ActiveEngine(), web_contents, content::JAVASCRIPT_DIALOG_TYPE_CONFIRM,
             {}, {}, true, &callback))
    std::move(callback).Run(false, {});
}

content::JavaScriptDialogManager* GetManager() {
  static base::NoDestructor<Manager> manager;
  return manager.get();
}

void Manager::CancelDialogs(content::WebContents* web_contents, bool reset_state) {
  (void)reset_state;
  std::vector<std::string> ids;
  for (const auto& [id, pending] : Pending())
    if (pending.contents == web_contents)
      ids.push_back(id);
  for (const auto& id : ids) {
    auto it = Pending().find(id);
    if (it != Pending().end())
      EmitDismiss(id, it->second);
    Finish(id, false, {});
  }
}

void Register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_JAVASCRIPT_DIALOG_REPLY,
                     SHAAR_OP_JAVASCRIPT_DIALOG_REPLY,
                     &HandleJavaScriptDialogOperation);
}

extern "C" void shaar_javascript_dialogs_register(
    ShaarModuleRegistry* registry) {
  Register(registry);
}

shaar_error_code HandleJavaScriptDialogOperation(
    shaar::ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, shaar_operation operation,
    shaar_bytes args_json, shaar_request_id request_id, shaar_reply_fn reply,
    void* reply_context, shaar_error* error) {
  if (operation != SHAAR_OP_JAVASCRIPT_DIALOG_REPLY || !context ||
      !context->browser_tabs || !window ||
      !tab || !reply || !request_id || scope.private_session || !scope.profile ||
      !args_json.data || args_json.size == 0 || args_json.size > 8192)
    return Fail(error, SHAAR_INVALID_ARGUMENT);
  auto parsed = base::JSONReader::Read(
      std::string_view(args_json.data, args_json.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict() ||
      parsed->GetDict().FindInt("schemaVersion") != 1)
    return Fail(error, SHAAR_INVALID_ARGUMENT);
  const std::string* id = parsed->GetDict().FindString("id");
  const std::string* input = parsed->GetDict().FindString("input");
  const std::optional<bool> accepted = parsed->GetDict().FindBool("accepted");
  if (!id || !input || input->size() > 4096 || !accepted)
    return Fail(error, SHAAR_INVALID_ARGUMENT);
  auto pending = Pending().find(*id);
  content::WebContents* contents = context->browser_tabs->FindWebContents(
      engine, window, tab);
  if (pending == Pending().end() || pending->second.engine != engine ||
      pending->second.contents != contents || pending->second.tab_id !=
          shaar::windows_tabs::Registry().TabID(engine, window, tab))
    return Fail(error, SHAAR_NOT_FOUND);
  const bool allow = *accepted &&
      shaar::windows_tabs::Registry().FindSelectedRegularTab(engine, contents)
          .has_value();
  Finish(*id, allow, allow ? base::UTF8ToUTF16(*input) : std::u16string());
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&ReplyLater, request_id, reply, reply_context));
  return SHAAR_OK;
}

}  // namespace shaar::javascript_dialogs
