// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/profiles/shaar_profiles.h"

#include <pthread.h>

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/callback.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/task/task_traits.h"
#include "base/threading/platform_thread.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/extensions/shaar_extensions.h"
#include "chrome/browser/shaar/devtools/shaar_agent_bridge.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/common/pref_names.h"
#include "components/content_settings/core/browser/cookie_settings.h"
#include "components/prefs/pref_service.h"
#include "components/content_settings/core/common/pref_names.h"
#include "components/language/core/browser/language_prefs.h"
#include "components/language/core/browser/pref_names.h"

struct shaar_profile {
  struct Waiter {
    shaar_reply_fn callback;
    void* context;
    shaar_request_id request_id;
  };
  shaar_engine* engine = nullptr;
  std::string id;
  std::string directory;
  base::FilePath deletion_path;
  Profile* native = nullptr;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive;
  shaar::profiles::ProfileHandleObserver native_observer;
  bool ready = false;
  bool deleting = false;
  std::vector<Waiter> waiters;
};

namespace {

constexpr char kThirdPartyCookiesKey[] = "profile.v1.thirdPartyCookiesBlocked";

std::map<std::pair<shaar_engine*, std::string>, std::unique_ptr<shaar_profile>>
    g_profiles;
std::vector<std::unique_ptr<shaar_profile>> g_retired_profiles;
thread_local std::string g_path_result;
thread_local std::string g_state_result;

bool IsRegisteredProfile(const shaar_profile* profile);

void CompleteProfileDeletion(shaar_engine* engine,
                             const std::string& id,
                             bool success) {
  auto found = g_profiles.find({engine, id});
  if (found == g_profiles.end() || !found->second->deleting)
    return;
  const std::string payload = success
                                  ? "{\"kind\":\"deleted\",\"schemaVersion\":1}"
                                  : "{\"kind\":\"delete_failed\",\"schemaVersion\":1}";
  shaar::EmitEvent(engine, SHAAR_EVENT_PROFILE, {id.data(), id.size()}, {}, {}, {},
                   {payload.data(), payload.size()});
  if (success) {
    g_retired_profiles.push_back(std::move(found->second));
    g_profiles.erase(found);
  } else {
    found->second->native_observer.SetWillBeDestroyedCallback({});
    found->second->deleting = false;
    found->second->ready = found->second->native != nullptr;
  }
}

bool DeleteProfileDirectory(const base::FilePath& path) {
  LOG(ERROR) << "Profile directory cleanup start path=" << path.AsUTF8Unsafe();
  for (int attempt = 0; attempt < 50; ++attempt) {
    if (!base::PathExists(path) || base::DeletePathRecursively(path)) {
      LOG(ERROR) << "Profile directory cleanup complete path="
                 << path.AsUTF8Unsafe() << " remains=" << base::PathExists(path);
      return true;
    }
    base::PlatformThread::Sleep(base::Milliseconds(100));
  }
  const bool removed = !base::PathExists(path);
  LOG(ERROR) << "Profile directory cleanup gave up path=" << path.AsUTF8Unsafe()
             << " removed=" << removed;
  return removed;
}

void DeleteProfileDirectoryAfterRelease(shaar_engine* engine,
                                        const std::string& id) {
  auto found = g_profiles.find({engine, id});
  if (found == g_profiles.end() || !found->second->deleting)
    return;
  const base::FilePath path = found->second->deletion_path;
  if (path.empty()) {
    CompleteProfileDeletion(engine, id, false);
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&DeleteProfileDirectory, path),
      base::BindOnce(&CompleteProfileDeletion, engine, id));
}

class ProfileServicesImpl final : public shaar::ProfileServices {
 public:
  Profile* ResolveProfile(shaar_engine* engine,
                          shaar_profile* handle) override {
    if (!engine || !IsRegisteredProfile(handle) || handle->engine != engine ||
        !handle->ready || handle->deleting) {
      return nullptr;
    }
    return handle->native;
  }

  std::string_view ProfileID(shaar_engine* engine,
                              shaar_profile* handle) override {
    return ResolveProfile(engine, handle) ? std::string_view(handle->id)
                                          : std::string_view();
  }

  KeyedService* GetKeyedService(shaar_engine* engine,
                                shaar_profile* handle,
                                KeyedServiceLookup lookup) override {
    Profile* profile = ResolveProfile(engine, handle);
    return profile && lookup ? lookup(profile) : nullptr;
  }
};

ProfileServicesImpl g_profile_services;

bool ValidBytes(shaar_bytes bytes) {
  return bytes.size == 0 || bytes.data != nullptr;
}

shaar_error_code Fail(shaar_error_code code,
                      const char* message,
                      shaar_error* error) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >= offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, std::char_traits<char>::length(message)};
  }
  return code;
}

std::string BytesToString(shaar_bytes bytes) {
  return bytes.size ? std::string(bytes.data, bytes.size) : std::string();
}

bool IsRegisteredProfile(const shaar_profile* profile) {
  if (!profile)
    return false;
  for (const auto& entry : g_profiles) {
    if (entry.second.get() == profile)
      return true;
  }
  return false;
}

void PostResult(shaar_reply_fn callback,
                void* context,
                shaar_request_id request_id,
                shaar_error_code code,
                std::string payload) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](shaar_reply_fn callback, void* context, shaar_request_id request_id,
             shaar_error_code code, std::string payload) {
            shaar_result result = {};
            result.size = sizeof(result);
            result.request_id = request_id;
            result.error.size = sizeof(result.error);
            result.error.code = code;
            result.payload_json = {payload.data(), payload.size()};
            callback(context, &result);
          },
          callback, context, request_id, code, std::move(payload)));
}

void Reply(shaar_reply_fn callback,
           void* context,
           shaar_request_id request_id,
           shaar_error_code code,
           const std::string& profile_id) {
  if (!callback)
    return;
  std::string payload;
  if (code == SHAAR_OK)
    payload = "{\"kind\":\"profile\",\"schemaVersion\":1,\"profile_id\":\"" +
              profile_id + "\"}";
  shaar_result result = {};
  result.size = sizeof(result);
  result.request_id = request_id;
  result.error.size = sizeof(result.error);
  result.error.code = code;
  result.payload_json = {payload.data(), payload.size()};
  callback(context, &result);
}

void ApplyDefaultHttpsOnlyMode(Profile* profile) {
  if (!profile)
    return;
  PrefService* prefs = profile->GetPrefs();
  if (!prefs)
    return;
  if (prefs->IsManagedPreference(prefs::kHttpsOnlyModeEnabled))
    return;
  if (prefs->HasPrefPath(prefs::kHttpsOnlyModeEnabled))
    return;
  prefs->SetBoolean(prefs::kHttpsOnlyModeEnabled, true);
}

void OnProfileReady(shaar_profile* handle,
                    shaar_reply_fn callback,
                    void* context,
                    shaar_request_id request_id,
                    Profile* profile) {
  if (!profile || profile->IsOffTheRecord()) {
    const std::string payload = "{\"kind\":\"load_failed\",\"schemaVersion\":1}";
    shaar::EmitEvent(handle->engine, SHAAR_EVENT_PROFILE,
                     {handle->id.data(), handle->id.size()}, {}, {},
                     {}, {payload.data(), payload.size()});
    Reply(callback, context, request_id, SHAAR_CHROMIUM_ERROR, handle->id);
    for (const auto& waiter : handle->waiters)
      Reply(waiter.callback, waiter.context, waiter.request_id,
            SHAAR_CHROMIUM_ERROR, handle->id);
    auto found = g_profiles.find({handle->engine, handle->id});
    if (found != g_profiles.end()) {
      g_retired_profiles.push_back(std::move(found->second));
      g_profiles.erase(found);
    }
    return;
  }
  if (!handle->engine->locale.empty()) {
    shaar::profiles::ApplyApplicationLocale(
        profile, g_browser_process->local_state(), handle->engine->locale);
  }
  handle->native = profile;
  handle->native_observer.Observe(profile, &handle->native);
  handle->keep_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kHeadlessCommand);
  if (!handle->keep_alive) {
    handle->native_observer.StopObserving();
    handle->native = nullptr;
    Reply(callback, context, request_id, SHAAR_NOT_READY, handle->id);
    for (const auto& waiter : handle->waiters)
      Reply(waiter.callback, waiter.context, waiter.request_id,
            SHAAR_NOT_READY, handle->id);
    auto found = g_profiles.find({handle->engine, handle->id});
    if (found != g_profiles.end()) {
      g_retired_profiles.push_back(std::move(found->second));
      g_profiles.erase(found);
    }
    return;
  }
  handle->ready = true;
  std::string framework_failure;
  if (!shaar::extensions_host::RegisterBundledFrameworkDevTools(
          profile, &framework_failure)) {
    LOG(ERROR) << "Shaar framework DevTools unavailable: " << framework_failure;
    const std::string framework_payload =
        "{\"kind\":\"frameworkDevToolsUnavailable\",\"schemaVersion\":1,\"reason\":\"" +
        framework_failure + "\"}";
    shaar::EmitEvent(handle->engine, SHAAR_EVENT_EXTENSION,
                     {handle->id.data(), handle->id.size()}, {}, {}, {},
                     {framework_payload.data(), framework_payload.size()});
  }
  const std::string payload = "{\"kind\":\"loaded\",\"schemaVersion\":1}";
  shaar::EmitEvent(handle->engine, SHAAR_EVENT_PROFILE,
                   {handle->id.data(), handle->id.size()}, {}, {},
                   {}, {payload.data(), payload.size()});
  // Keep this below patch 0033's hunk. The reply is what the app waits on.
  ApplyDefaultHttpsOnlyMode(profile);
  Reply(callback, context, request_id, SHAAR_OK, handle->id);
  for (const auto& waiter : handle->waiters)
    Reply(waiter.callback, waiter.context, waiter.request_id, SHAAR_OK, handle->id);
  handle->waiters.clear();
}

shaar_error_code ReserveAndLoad(shaar_engine* engine,
                                shaar_bytes id_bytes,
                                shaar_bytes directory_bytes,
                                bool create,
                                shaar_bytes display_name,
                                shaar_request_id request_id,
                                shaar_reply_fn callback,
                                void* context,
                                shaar_profile** out,
                                shaar_error* error,
                                bool idempotent_open) {
  if (!engine || !out || !pthread_main_np() || !ValidBytes(id_bytes) ||
      !ValidBytes(directory_bytes) || !ValidBytes(display_name) || !callback ||
      request_id == 0)
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile request", error);
  *out = nullptr;
  std::string canonical;
  if (!shaar::profiles::CanonicalDirectory(id_bytes, &canonical))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile identity", error);
  const std::string id = BytesToString(id_bytes);
  if (BytesToString(directory_bytes) != canonical)
    return Fail(SHAAR_INVALID_ARGUMENT, "profile directory mismatch", error);
  if (create && (display_name.size > 256 ||
                 (display_name.size &&
                  !base::IsStringUTF8(BytesToString(display_name)))))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile display name", error);
  auto existing = g_profiles.find({engine, id});
  if (existing != g_profiles.end()) {
    if (!idempotent_open || existing->second->deleting)
      return Fail(SHAAR_CONFLICT, "profile is already open or deleting", error);
    *out = existing->second.get();
    if (existing->second->ready) {
      const std::string result =
          "{\"kind\":\"profile\",\"schemaVersion\":1,\"profile_id\":\"" +
          id + "\"}";
      PostResult(callback, context, request_id, SHAAR_OK, result);
    } else {
      existing->second->waiters.push_back({callback, context, request_id});
    }
    return Fail(SHAAR_OK, "", error);
  }
  if (!g_browser_process || !g_browser_process->profile_manager())
    return Fail(SHAAR_NOT_READY, "profile manager is unavailable", error);

  ProfileManager* manager = g_browser_process->profile_manager();
  const base::FilePath relative = base::FilePath::FromUTF8Unsafe(canonical);
  const base::FilePath configured_root =
      base::FilePath::FromUTF8Unsafe(engine->data_root);
  if (!configured_root.IsAbsolute() ||
      configured_root != manager->user_data_dir())
    return Fail(SHAAR_CONFLICT, "engine data root does not match profile manager", error);
  const base::FilePath path = configured_root.Append(relative);
  if (path.DirName() != configured_root)
    return Fail(SHAAR_INVALID_ARGUMENT, "profile path escapes data root", error);
  if (base::IsLink(path))
    return Fail(SHAAR_INVALID_ARGUMENT, "profile path cannot be a symbolic link", error);
  if (create && display_name.size && base::PathExists(path))
    return Fail(SHAAR_CONFLICT, "profile directory already exists", error);

  auto handle = std::make_unique<shaar_profile>();
  handle->engine = engine;
  handle->id = id;
  handle->directory = canonical;
  shaar_profile* raw_handle = handle.get();
  g_profiles.emplace(std::make_pair(engine, id), std::move(handle));
  *out = raw_handle;

  auto loaded = base::BindOnce(&OnProfileReady, raw_handle, callback, context,
                               request_id);
  loaded = base::BindPostTaskToCurrentDefault(std::move(loaded));
  if (create) {
    const std::string name = BytesToString(display_name);
    manager->CreateProfileAsync(
        path, std::move(loaded),
        base::BindOnce(
            [](base::FilePath path, std::string name, shaar_profile* handle,
               Profile* profile) {
              if (!profile)
                return;
              if (!name.empty()) {
                auto* entry = g_browser_process->profile_manager()
                                  ->GetProfileAttributesStorage()
                                  .GetProfileAttributesWithPath(path);
                if (entry)
                  entry->SetLocalProfileName(base::UTF8ToUTF16(name), false);
              }
              const std::string payload =
                  "{\"kind\":\"created\",\"schemaVersion\":1}";
              shaar::EmitEvent(handle->engine, SHAAR_EVENT_PROFILE,
                               {handle->id.data(), handle->id.size()}, {}, {},
                               {}, {payload.data(), payload.size()});
            },
            path, name, raw_handle));
  } else if (!manager->LoadProfileByPath(path, false, std::move(loaded))) {
    g_profiles.erase({engine, id});
    *out = nullptr;
    return Fail(SHAAR_NOT_FOUND, "profile directory does not exist", error);
  }
  return Fail(SHAAR_OK, "", error);
}

}  // namespace

namespace shaar::profiles {

ProfileHandleObserver::~ProfileHandleObserver() {
  StopObserving();
}

void ProfileHandleObserver::Observe(Profile* profile, Profile** slot) {
  StopObserving();
  observed_ = profile;
  slot_ = slot;
  if (observed_)
    observed_->AddObserver(this);
}

void ProfileHandleObserver::StopObserving() {
  if (observed_)
    observed_->RemoveObserver(this);
  observed_ = nullptr;
  slot_ = nullptr;
  will_be_destroyed_callback_.Reset();
}

void ProfileHandleObserver::SetWillBeDestroyedCallback(
    base::OnceClosure callback) {
  will_be_destroyed_callback_ = std::move(callback);
}

void ProfileHandleObserver::OnProfileWillBeDestroyed(Profile* profile) {
  if (profile != observed_)
    return;
  if (slot_)
    *slot_ = nullptr;
  base::OnceClosure callback = std::move(will_be_destroyed_callback_);
  StopObserving();
  if (callback)
    std::move(callback).Run();
}

void ApplyApplicationLocale(Profile* profile,
                            PrefService* local_state,
                            const std::string& locale) {
  if (!profile || !local_state || locale.empty()) {
    return;
  }

  local_state->SetString(language::prefs::kApplicationLocale, locale);
  language::LanguagePrefs language_prefs(profile->GetPrefs());
  std::vector<std::string> selected_languages;
  language_prefs.GetUserSelectedLanguagesList(&selected_languages);
  std::vector<std::string> ordered_languages = {locale};
  for (const std::string& language : selected_languages) {
    if (!language.empty() && language != locale) {
      ordered_languages.push_back(language);
    }
  }
  language_prefs.SetUserSelectedLanguagesList(ordered_languages);
}

}  // namespace shaar::profiles

namespace {

shaar_error_code HandleProfileOperation(
    shaar::ShaarEngineContext*,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window*,
    shaar_tab*,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn callback,
    void* context,
    shaar_error* error) {
  if (!engine || !callback || request_id == 0 || !ValidBytes(args_json))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile operation", error);
  if (scope.size < sizeof(scope) ||
      (scope.profile && scope.private_session))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile scope", error);
  if (!scope.profile) {
    if (scope.private_session)
      return Fail(SHAAR_PRIVATE_DISALLOWED,
                  "profile state is unavailable in private sessions", error);
    return Fail(SHAAR_INVALID_ARGUMENT, "profile scope is required", error);
  }
  if (!IsRegisteredProfile(scope.profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (scope.profile->engine != engine)
    return Fail(SHAAR_WRONG_PROFILE, "profile belongs to another engine", error);
  if (!scope.profile->ready || !scope.profile->native)
    return Fail(SHAAR_NOT_READY, "profile is not ready", error);
  if (scope.profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);

  auto parsed = base::JSONReader::Read(BytesToString(args_json), base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict() ||
      parsed->GetDict().FindInt("schemaVersion") != 1) {
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile operation payload", error);
  }
  const base::DictValue& args = parsed->GetDict();
  if (operation == SHAAR_OP_PROFILE_DELETE) {
    if (args.size() != 1)
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown profile delete fields", error);
    const shaar_error_code status = shaar_profile_delete(scope.profile, error);
    if (status != SHAAR_OK)
      return status;
    PostResult(callback, context, request_id, SHAAR_OK,
               "{\"schemaVersion\":1,\"scheduled\":true}");
    return SHAAR_OK;
  }

  const std::string* key = args.FindString("key");
  if (!key)
    return Fail(SHAAR_INVALID_ARGUMENT, "profile state key is required", error);

  if (operation == SHAAR_OP_PROFILE_GET_STATE) {
    if (args.size() != 2)
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown profile state fields", error);
    shaar_bytes key_bytes{key->data(), key->size()};
    shaar_bytes value = {};
    const shaar_error_code status =
        shaar_profile_get_state(scope.profile, key_bytes, &value, error);
    if (status != SHAAR_OK)
      return status;
    std::string payload = "{\"schemaVersion\":1,\"value\":";
    payload.append(value.data, value.size);
    payload.push_back('}');
    PostResult(callback, context, request_id, SHAAR_OK, std::move(payload));
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_PROFILE_SET_STATE) {
    if (args.size() != 3)
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown profile state fields", error);
    const base::Value* value = args.Find("value");
    if (!value || !value->is_bool())
      return Fail(SHAAR_INVALID_ARGUMENT, "profile state value must be boolean", error);
    const std::string value_json = value->GetBool() ? "true" : "false";
    shaar_bytes previous = {};
    const shaar_error_code read_status = shaar_profile_get_state(
        scope.profile, {key->data(), key->size()}, &previous, error);
    if (read_status != SHAAR_OK)
      return read_status;
    const bool changed =
        std::string(previous.data, previous.size) != value_json;
    const shaar_error_code status = shaar_profile_set_state(
        scope.profile, {key->data(), key->size()},
        {value_json.data(), value_json.size()}, error);
    if (status != SHAAR_OK)
      return status;
    const std::string payload = changed
                                    ? "{\"schemaVersion\":1,\"changed\":true}"
                                    : "{\"schemaVersion\":1,\"changed\":false}";
    PostResult(callback, context, request_id, SHAAR_OK, payload);
    return SHAAR_OK;
  }
  return Fail(SHAAR_UNSUPPORTED_CAPABILITY, "unsupported profile operation", error);
}

}  // namespace

extern "C" void shaar_profiles_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  shaar::SetProfileServices(&g_profile_services);
  registry->Register(SHAAR_OP_PROFILE_DELETE, SHAAR_OP_PROFILE_DELETE,
                    &HandleProfileOperation);
  registry->Register(SHAAR_OP_PROFILE_GET_STATE, SHAAR_OP_PROFILE_GET_STATE,
                    &HandleProfileOperation);
  registry->Register(SHAAR_OP_PROFILE_SET_STATE, SHAAR_OP_PROFILE_SET_STATE,
                    &HandleProfileOperation);
}

namespace shaar::profiles {

bool CanonicalDirectory(shaar_bytes profile_id, std::string* directory) {
  if (!directory || !profile_id.data || profile_id.size != 36)
    return false;
  const std::string id(profile_id.data, profile_id.size);
  for (size_t i = 0; i < id.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (id[i] != '-')
        return false;
    } else if (!((id[i] >= '0' && id[i] <= '9') ||
                 (id[i] >= 'a' && id[i] <= 'f'))) {
      return false;
    }
  }
  *directory = "Profile " + id;
  return true;
}

}  // namespace shaar::profiles

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_open(
    shaar_engine* engine,
    shaar_bytes profile_id,
    shaar_bytes directory,
    int create_if_missing,
    shaar_request_id request_id,
    shaar_reply_fn callback,
    void* reply_context,
    shaar_profile** out,
    shaar_error* error) {
  if (create_if_missing != 0 && create_if_missing != 1)
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid create flag", error);
  return ReserveAndLoad(
      engine, profile_id, directory, create_if_missing != 0,
      {}, request_id, callback, reply_context, out, error, true);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_create(
    shaar_engine* engine,
    shaar_bytes profile_id,
    shaar_bytes display_name,
    shaar_request_id request_id,
    shaar_reply_fn callback,
    void* reply_context,
    shaar_profile** out,
    shaar_error* error) {
  if (display_name.size == 0)
    return Fail(SHAAR_INVALID_ARGUMENT, "profile display name is required", error);
  std::string directory;
  if (!shaar::profiles::CanonicalDirectory(profile_id, &directory))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile identity", error);
  return ReserveAndLoad(
      engine, profile_id, {directory.data(), directory.size()}, true,
      display_name, request_id, callback, reply_context, out, error, false);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_close(
    shaar_profile* profile, shaar_error* error) {
  if (!profile || !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile handle", error);
  if (!IsRegisteredProfile(profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (!profile->ready)
    return Fail(SHAAR_CONFLICT, "profile load is pending", error);
  if (profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);
  auto found = g_profiles.find({profile->engine, profile->id});
  if (found != g_profiles.end()) {
    const std::string payload = "{\"kind\":\"closed\",\"schemaVersion\":1}";
    shaar::EmitEvent(profile->engine, SHAAR_EVENT_PROFILE,
                     {profile->id.data(), profile->id.size()}, {}, {},
                     {}, {payload.data(), payload.size()});
    found->second->native_observer.StopObserving();
    found->second->native = nullptr;
    found->second->keep_alive.reset();
    g_retired_profiles.push_back(std::move(found->second));
    g_profiles.erase(found);
  }
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_get_path(
    shaar_profile* profile, shaar_bytes* path, shaar_error* error) {
  if (!profile || !path || !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile path request", error);
  if (!IsRegisteredProfile(profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (!profile->ready || !profile->native)
    return Fail(SHAAR_NOT_READY, "profile is not ready", error);
  if (profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);
  g_path_result = profile->native->GetPath().AsUTF8Unsafe();
  *path = {g_path_result.data(), g_path_result.size()};
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_get_state(
    shaar_profile* profile,
    shaar_bytes state_key,
    shaar_bytes* value_json,
    shaar_error* error) {
  if (!profile || !value_json || !ValidBytes(state_key) || !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile state request", error);
  if (!IsRegisteredProfile(profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (!profile->ready || !profile->native)
    return Fail(SHAAR_NOT_READY, "profile is not ready", error);
  if (profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);
  if (BytesToString(state_key) != kThirdPartyCookiesKey)
    return Fail(SHAAR_INVALID_ARGUMENT, "unknown profile state key", error);
  const bool blocked = profile->native->GetPrefs()->GetInteger(
                           prefs::kCookieControlsMode) ==
                       static_cast<int>(content_settings::CookieControlsMode::kBlockThirdParty);
  g_state_result = blocked ? "true" : "false";
  *value_json = {g_state_result.data(), g_state_result.size()};
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_set_state(
    shaar_profile* profile,
    shaar_bytes state_key,
    shaar_bytes value_json,
    shaar_error* error) {
  if (!profile || !ValidBytes(state_key) || !ValidBytes(value_json) ||
      !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile state request", error);
  if (!IsRegisteredProfile(profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (!profile->ready || !profile->native)
    return Fail(SHAAR_NOT_READY, "profile is not ready", error);
  if (profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);
  if (BytesToString(state_key) != kThirdPartyCookiesKey)
    return Fail(SHAAR_INVALID_ARGUMENT, "unknown profile state key", error);
  const std::string value = BytesToString(value_json);
  if (value != "true" && value != "false")
    return Fail(SHAAR_INVALID_ARGUMENT, "profile state must be boolean", error);
  PrefService* prefs = profile->native->GetPrefs();
  if (prefs->IsManagedPreference(prefs::kCookieControlsMode))
    return Fail(SHAAR_POLICY_BLOCKED, "profile state is managed", error);
  const int next = static_cast<int>(
      value == "true" ? content_settings::CookieControlsMode::kBlockThirdParty
                      : content_settings::CookieControlsMode::kIncognitoOnly);
  if (prefs->GetInteger(prefs::kCookieControlsMode) != next) {
    prefs->SetInteger(prefs::kCookieControlsMode, next);
    const std::string payload =
        "{\"kind\":\"state_changed\",\"schemaVersion\":1,\"key\":\"" +
        std::string(kThirdPartyCookiesKey) + "\"}";
    shaar::EmitEvent(profile->engine, SHAAR_EVENT_PROFILE,
                     {profile->id.data(), profile->id.size()}, {}, {},
                     {}, {payload.data(), payload.size()});
  }
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_set_https_only(
    shaar_profile* profile, int enabled, shaar_error* error) {
  if (!profile || !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid https-only request", error);
  if (enabled != 0 && enabled != 1)
    return Fail(SHAAR_INVALID_ARGUMENT, "https-only must be 0 or 1", error);
  if (!IsRegisteredProfile(profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (!profile->ready || !profile->native)
    return Fail(SHAAR_NOT_READY, "profile is not ready", error);
  if (profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);
  PrefService* prefs = profile->native->GetPrefs();
  if (!prefs)
    return Fail(SHAAR_NOT_READY, "profile preferences are unavailable", error);
  if (prefs->IsManagedPreference(prefs::kHttpsOnlyModeEnabled))
    return Fail(SHAAR_POLICY_BLOCKED, "https-only mode is managed", error);
  const bool next = enabled == 1;
  if (prefs->GetBoolean(prefs::kHttpsOnlyModeEnabled) != next)
    prefs->SetBoolean(prefs::kHttpsOnlyModeEnabled, next);
  return Fail(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_profile_delete(
    shaar_profile* profile, shaar_error* error) {
  if (!profile || !pthread_main_np())
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid profile handle", error);
  if (!IsRegisteredProfile(profile))
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (!profile->ready || !profile->native)
    return Fail(SHAAR_NOT_READY, "profile is not ready", error);
  if (profile->deleting)
    return Fail(SHAAR_CONFLICT, "profile deletion is pending", error);
  if (!g_browser_process || !g_browser_process->profile_manager())
    return Fail(SHAAR_SHUTTING_DOWN, "profile manager is shutting down", error);
  ProfileManager* manager = g_browser_process->profile_manager();
  if (profile->native->GetPrimaryOTRProfile(/*create_if_needed=*/false))
    return Fail(SHAAR_CONFLICT, "profile has an active private context", error);
  ProfileBrowserCollection* browsers =
      ProfileBrowserCollection::GetForProfile(profile->native);
  if (browsers && (!browsers->IsEmpty() ||
                   browsers->GetOffTheRecordBrowserCount() != 0))
    return Fail(SHAAR_CONFLICT, "profile still owns browser windows", error);
  const auto keep_alives = manager->GetKeepAlivesByPath(profile->native->GetPath());
  for (const auto& keep_alive : keep_alives) {
    const int own_lease =
        keep_alive.first == ProfileKeepAliveOrigin::kHeadlessCommand ? 1 : 0;
    if (keep_alive.second > own_lease)
      return Fail(SHAAR_CONFLICT, "profile still has a keep-alive", error);
  }
  ProfileAttributesEntry* attributes =
      manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(
          profile->native->GetPath());
  if (!attributes || attributes->IsEphemeral())
    return Fail(SHAAR_CONFLICT, "profile is unavailable for deletion", error);
  shaar::agent_bridge::RevokeForProfile(profile->engine, profile);
  profile->deleting = true;
  const std::string deleting = "{\"kind\":\"deleting\",\"schemaVersion\":1}";
  shaar::EmitEvent(profile->engine, SHAAR_EVENT_PROFILE,
                   {profile->id.data(), profile->id.size()}, {}, {},
                   {}, {deleting.data(), deleting.size()});
  profile->native_observer.SetWillBeDestroyedCallback(base::BindOnce(
      [](shaar_engine* engine, std::string id) {
        base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE,
        base::BindOnce(&DeleteProfileDirectoryAfterRelease, engine,
                       std::move(id)));
      },
      profile->engine, profile->id));
  // Releasing our lease can unload the profile. Deletion uses only its path.
  const base::FilePath path = profile->native->GetPath();
  profile->deletion_path = path;
  profile->keep_alive.reset();
  manager->GetDeleteProfileHelper().MaybeScheduleProfileForDeletion(
      path,
      base::BindOnce(
          [](shaar_engine* engine, std::string id, Profile* deleted_profile) {
            if (!deleted_profile)
              CompleteProfileDeletion(engine, id, false);
          },
          profile->engine, profile->id),
      ProfileMetrics::DELETE_PROFILE_SETTINGS);
  return Fail(SHAAR_OK, "", error);
}
