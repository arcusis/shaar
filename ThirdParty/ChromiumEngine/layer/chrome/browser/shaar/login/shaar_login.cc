// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/login/shaar_login.h"

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "content/public/browser/web_contents.h"
#include "net/base/auth.h"

namespace shaar::login {
namespace {

constexpr shaar_operation kCredentialsReply =
    SHAAR_OP_HTTP_AUTH_CREDENTIALS_REPLY;
constexpr size_t kMaximumPayloadBytes = 4096;

struct Pending {
  shaar_engine* engine;
  content::WebContents* contents;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  content::LoginDelegate::LoginAuthRequiredCallback callback;
};

using PendingMap = std::map<std::string, Pending>;
PendingMap& Requests() {
  static base::NoDestructor<PendingMap> requests;
  return *requests;
}
uint64_t& NextID() {
  static uint64_t next = 0;
  return next;
}

class ShaarLoginDelegate final : public content::LoginDelegate {
 public:
  explicit ShaarLoginDelegate(std::string id) : id_(std::move(id)) {}
  ~ShaarLoginDelegate() override {
    auto found = Requests().find(id_);
    if (found == Requests().end())
      return;
    const Pending& pending = found->second;
    if (lifecycle::EngineIsReady(pending.engine)) {
      base::Value::Dict payload;
      payload.Set("schemaVersion", 1);
      payload.Set("kind", "httpAuthDismissed");
      payload.Set("id", id_);
      std::string json;
      if (base::JSONWriter::Write(payload, &json))
        shaar::EmitEvent(pending.engine, SHAAR_EVENT_PERMISSION,
                         {pending.profile_id.data(), pending.profile_id.size()}, {},
                         {pending.window_id.data(), pending.window_id.size()},
                         {pending.tab_id.data(), pending.tab_id.size()},
                         {json.data(), json.size()});
    }
    Requests().erase(found);
  }

 private:
  std::string id_;
};

void DeliverReply(shaar_request_id request_id,
                  shaar_reply_fn callback,
                  void* context,
                  base::Value payload) {
  std::string json;
  base::JSONWriter::Write(payload, &json);
  shaar_result result = {};
  result.size = sizeof(result);
  result.request_id = request_id;
  result.error.size = sizeof(result.error);
  result.error.code = SHAAR_OK;
  result.payload_json = {json.data(), json.size()};
  callback(context, &result);
}

shaar_error_code ReplyOperation(
    shaar::ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, shaar_operation operation, shaar_bytes bytes,
    shaar_request_id request_id, shaar_reply_fn reply, void* reply_context,
    shaar_error*) {
  if (operation != kCredentialsReply || !bytes.data || !bytes.size ||
      bytes.size > kMaximumPayloadBytes || !request_id || !reply || !context ||
      !context->browser_tabs || !window || !tab || !scope.profile ||
      scope.private_session)
    return SHAAR_INVALID_ARGUMENT;
  auto parsed = base::JSONReader::Read(
      std::string_view(bytes.data, bytes.size), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return SHAAR_INVALID_ARGUMENT;
  const auto& dict = parsed->GetDict();
  const std::string* id = dict.FindString("id");
  const std::optional<bool> cancelled = dict.FindBool("cancelled");
  auto found = id ? Requests().find(*id) : Requests().end();
  if (!id || found == Requests().end() || found->second.engine != engine)
    return SHAAR_NOT_FOUND;
  if (!cancelled || dict.FindInt("schemaVersion") != 1)
    return SHAAR_INVALID_ARGUMENT;
  for (const auto item : dict) {
    if (item.first != "schemaVersion" && item.first != "id" &&
        item.first != "cancelled" && item.first != "username" &&
        item.first != "password")
      return SHAAR_INVALID_ARGUMENT;
  }
  content::WebContents* contents =
      context->browser_tabs->FindWebContents(engine, window, tab);
  if (!contents)
    return SHAAR_NOT_FOUND;
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  if (found->second.contents != contents || !identity ||
      identity->profile_id != found->second.profile_id ||
      identity->window_id != found->second.window_id ||
      identity->tab_id != found->second.tab_id)
    return SHAAR_NOT_FOUND;
  Profile* profile = context->profile_services
                         ? context->profile_services->ResolveProfile(
                               engine, scope.profile)
                         : nullptr;
  if (!profile ||
      profile != Profile::FromBrowserContext(contents->GetBrowserContext()))
    return SHAAR_WRONG_PROFILE;

  std::optional<net::AuthCredentials> credentials;
  if (!*cancelled) {
    const std::string* username = dict.FindString("username");
    const std::string* password = dict.FindString("password");
    if (!username || !password || username->size() > 1024 ||
        password->size() > 2048)
      return SHAAR_INVALID_ARGUMENT;
    credentials.emplace(base::UTF8ToUTF16(*username),
                        base::UTF8ToUTF16(*password));
  } else if (dict.FindString("username") || dict.FindString("password")) {
    return SHAAR_INVALID_ARGUMENT;
  }
  auto callback = std::move(found->second.callback);
  Requests().erase(found);
  std::move(callback).Run(credentials);
  base::Value::Dict result;
  result.Set("schemaVersion", 1);
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&DeliverReply, request_id, reply, reply_context,
                                base::Value(std::move(result))));
  return SHAAR_OK;
}

}  // namespace

std::unique_ptr<content::LoginDelegate> CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* web_contents,
    content::LoginAuthRequiredCallback callback) {
  shaar_engine* engine = lifecycle::ActiveEngine();
  if (!web_contents || !callback || !lifecycle::EngineIsReady(engine))
    return nullptr;
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(engine, web_contents);
  if (!identity ||
      identity->profile_id.empty() || identity->window_id.empty() ||
      identity->tab_id.empty() || Requests().size() >= 8)
    return nullptr;

  const std::string id = std::to_string(++NextID());
  base::Value::Dict payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "httpAuthRequested");
  payload.Set("id", id);
  payload.Set("realm", auth_info.realm);
  payload.Set("host", auth_info.challenger.host());
  std::string json;
  if (!base::JSONWriter::Write(payload, &json))
    return nullptr;
  Requests().emplace(id, Pending{engine, web_contents, identity->profile_id,
                                 identity->window_id, identity->tab_id,
                                 std::move(callback)});
  const auto status = shaar::EmitEvent(
      engine, SHAAR_EVENT_PERMISSION,
      {identity->profile_id.data(), identity->profile_id.size()}, {},
      {identity->window_id.data(), identity->window_id.size()},
      {identity->tab_id.data(), identity->tab_id.size()},
      {json.data(), json.size()});
  if (status != SHAAR_OK) {
    Requests().erase(id);
    return nullptr;
  }
  return std::make_unique<ShaarLoginDelegate>(id);
}

}  // namespace shaar::login

extern "C" void shaar_login_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_HTTP_AUTH_CREDENTIALS_REPLY,
                     SHAAR_OP_HTTP_AUTH_CREDENTIALS_REPLY,
                     &shaar::login::ReplyOperation);
}
