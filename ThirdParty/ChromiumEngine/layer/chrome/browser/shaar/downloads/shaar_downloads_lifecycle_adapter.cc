// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/downloads/shaar_downloads.h"

#include <map>
#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/task/sequenced_task_runner.h"
#include "base/supports_user_data.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"

namespace {

const int kDownloadsUserDataKey = 0;

class PerEngineDownloads final : public base::SupportsUserData::Data {
 public:
  shaar::Downloads* Get(Profile* profile,
                        shaar_engine* engine,
                        std::string_view profile_id) {
    auto& downloads = instances_[engine];
    if (!downloads) {
      downloads = std::make_unique<shaar::Downloads>(
          profile, std::string(profile_id), std::string(), &EmitDownloadEvent,
          engine);
    }
    return downloads.get();
  }

 private:
  static void EmitDownloadEvent(void* context,
                                const std::string& profile_id,
                                const std::string& session_id,
                                const base::Value::Dict& event) {
    std::string payload;
    if (!base::JSONWriter::Write(event, &payload))
      return;
    shaar::EmitEvent(static_cast<shaar_engine*>(context), SHAAR_EVENT_DOWNLOAD,
                     {profile_id.data(), profile_id.size()},
                     {session_id.data(), session_id.size()}, {}, {},
                     {payload.data(), payload.size()});
  }

  std::map<shaar_engine*, std::unique_ptr<shaar::Downloads>> instances_;
};

PerEngineDownloads* GetDownloadsData(Profile* profile) {
  auto* data = static_cast<PerEngineDownloads*>(
      profile->GetUserData(&kDownloadsUserDataKey));
  if (!data) {
    auto owned = std::make_unique<PerEngineDownloads>();
    data = owned.get();
    profile->SetUserData(&kDownloadsUserDataKey, std::move(owned));
  }
  return data;
}

shaar_error_code DecodeError(std::string_view value) {
  if (value == "SHAAR_INVALID_ARGUMENT")
    return SHAAR_INVALID_ARGUMENT;
  if (value == "SHAAR_NOT_READY")
    return SHAAR_NOT_READY;
  if (value == "SHAAR_NOT_FOUND")
    return SHAAR_NOT_FOUND;
  if (value == "SHAAR_POLICY_BLOCKED")
    return SHAAR_POLICY_BLOCKED;
  if (value == "SHAAR_CONFLICT")
    return SHAAR_CONFLICT;
  if (value == "SHAAR_IO_ERROR")
    return SHAAR_IO_ERROR;
  if (value == "SHAAR_UNSUPPORTED_CAPABILITY")
    return SHAAR_UNSUPPORTED_CAPABILITY;
  return SHAAR_CHROMIUM_ERROR;
}

shaar_error_code HandleLifecycleDownload(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window*,
    shaar_tab*,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error*) {
  if (!context || !context->profile_services || !engine || !reply ||
      !scope.profile || scope.private_session ||
      (args_json.size && !args_json.data))
    return scope.private_session ? SHAAR_PRIVATE_DISALLOWED
                                 : SHAAR_INVALID_ARGUMENT;
  Profile* profile =
      context->profile_services->ResolveProfile(engine, scope.profile);
  const std::string_view profile_id =
      context->profile_services->ProfileID(engine, scope.profile);
  if (!profile || profile_id.empty())
    return SHAAR_NOT_FOUND;
  auto* downloads = GetDownloadsData(profile)->Get(profile, engine, profile_id);
  std::string payload;
  std::string diagnostic;
  const std::string arguments(args_json.data ? args_json.data : "",
                              args_json.size);
  if (!downloads->Handle(operation, arguments, &payload, &diagnostic))
    return DecodeError(diagnostic);

  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](shaar_reply_fn callback, void* callback_context,
             shaar_request_id id, std::string result_json) {
            shaar_result result = {};
            result.size = sizeof(result);
            result.request_id = id;
            result.error.size = sizeof(result.error);
            result.error.code = SHAAR_OK;
            result.payload_json = {result_json.data(), result_json.size()};
            callback(callback_context, &result);
          },
          reply, reply_context, request_id, std::move(payload)));
  return SHAAR_OK;
}

}  // namespace

extern "C" void shaar_downloads_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_DOWNLOAD_LIST, SHAAR_OP_DOWNLOAD_DIRECTORY,
                     &HandleLifecycleDownload);
}
