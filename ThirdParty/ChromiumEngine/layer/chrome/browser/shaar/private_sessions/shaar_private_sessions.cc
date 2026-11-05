// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/private_sessions/shaar_private_sessions.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_sessions_module.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_trackers.h"

#include <cstring>
#include <map>
#include <pthread.h>
#include <utility>

#include "base/check.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_util.h"
#include "chrome/common/pref_names.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/prefs/pref_service.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace shaar {

PrivateSessionRegistry::PrivateSessionRegistry(EventSink event_sink)
    : event_sink_(std::move(event_sink)) {}
PrivateSessionRegistry::~PrivateSessionRegistry() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  DCHECK(sessions_.empty());
}

shaar_error_code PrivateSessionRegistry::Open(
    Profile* parent,
    const std::string& profile_id,
    const std::string& session_id,
    Session** out) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!out)
    return SHAAR_INVALID_ARGUMENT;
  *out = nullptr;
  if (!parent || profile_id.empty() || session_id.empty() ||
      !base::IsStringUTF8(profile_id) || !base::IsStringUTF8(session_id))
    return SHAAR_INVALID_ARGUMENT;
  if (parent->IsOffTheRecord() || parent->GetOriginalProfile() != parent)
    return SHAAR_WRONG_PROFILE;

  auto found = sessions_.find(session_id);
  if (found != sessions_.end()) {
    Session& session = *found->second;
    if (session.parent != parent || session.profile_id != profile_id)
      return SHAAR_WRONG_PROFILE;
    if (session.closing)
      return SHAAR_CONFLICT;
    ++session.open_handles;
    *out = &session;
    return SHAAR_OK;
  }
  if (retired_ids_.contains(session_id))
    return SHAAR_CONFLICT;

  const bool already_has_otr =
      parent->GetPrimaryOTRProfile(/*create_if_needed=*/false) != nullptr;
  Profile* otr = parent->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  if (!otr || !otr->IsOffTheRecord() || otr->GetOriginalProfile() != parent)
    return SHAAR_CHROMIUM_ERROR;

  const shaar_error_code privacy = ConfigurePrivateProfile(otr);
  if (privacy != SHAAR_OK) {
    if (!already_has_otr)
      parent->DestroyOffTheRecordProfile(otr);
    return privacy;
  }

  auto session = std::make_unique<Session>();
  session->id = session_id;
  session->profile_id = profile_id;
  session->parent = parent;
  session->otr = otr;
  session->open_handles = 1;
  auto [parent_entry, new_parent] = parent_sessions_.try_emplace(parent);
  if (new_parent)
    parent->AddObserver(this);
  Session* handle = session.get();
  storage_.push_back(std::move(session));
  auto [inserted, ok] = sessions_.emplace(session_id, handle);
  CHECK(ok);
  parent_entry->second.insert(session_id);
  Emit(*inserted->second, EventState::kOpened);
  *out = inserted->second;
  return SHAAR_OK;
}

bool PrivateSessionRegistry::Close(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->open_handles == 0)
    return false;
  --session->open_handles;
  if (session->open_handles == 0) {
    session->closing = true;
    Emit(*session, EventState::kClosing);
  }
  MaybeRetire(session);
  return true;
}

bool PrivateSessionRegistry::RetainChild(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->closing)
    return false;
  ++session->children;
  return true;
}

bool PrivateSessionRegistry::ReleaseChild(Session* session) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->children == 0)
    return false;
  --session->children;
  MaybeRetire(session);
  return true;
}

void PrivateSessionRegistry::OnProfileWillBeDestroyed(Profile* profile) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto parent = parent_sessions_.find(profile);
  if (parent == parent_sessions_.end())
    return;
  profile->RemoveObserver(this);
  TrackerProtection().RemoveProfile(profile);
  for (const std::string& session_id : parent->second) {
    auto session = sessions_.find(session_id);
    if (session == sessions_.end())
      continue;
    if (!session->second->closing)
      Emit(*session->second, EventState::kClosing);
    Emit(*session->second, EventState::kClosed);
    session->second->closing = true;
    session->second->open_handles = 0;
    retired_ids_.insert(session->first);
    session->second->parent = nullptr;
    TrackerProtection().RemoveProfile(session->second->otr);
    session->second->otr = nullptr;
    sessions_.erase(session);
  }
  parent_sessions_.erase(parent);
}

PrivateSessionRegistry::Session* PrivateSessionRegistry::Find(
    Profile* parent,
    const std::string& session_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  auto found = sessions_.find(session_id);
  if (found == sessions_.end() || found->second->closing ||
      found->second->parent != parent) {
    return nullptr;
  }
  return found->second;
}

bool PrivateSessionRegistry::Resolve(const Session *session, Profile **parent,
                                     Profile **otr,
                                     std::string_view *profile_id,
                                     std::string_view *session_id) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsLive(session) || session->closing || !session->parent || !session->otr)
    return false;
  if (parent)
    *parent = session->parent;
  if (otr)
    *otr = session->otr;
  if (profile_id)
    *profile_id = session->profile_id;
  if (session_id)
    *session_id = session->id;
  return true;
}

shaar_error_code PrivateCookieSetting(Profile *otr, std::string_view origin,
                                      bool set, bool allow, bool *allowed) {
  if (!otr || !otr->IsOffTheRecord())
    return SHAAR_WRONG_PROFILE;
  if (!allowed || origin.empty() || origin.size() > 4096)
    return SHAAR_INVALID_ARGUMENT;
  GURL site{std::string(origin)};
  const GURL canonical = url::Origin::Create(site).GetURL();
  std::string canonical_text = canonical.spec();
  if (!canonical_text.empty() && canonical_text.back() == '/')
    canonical_text.pop_back();
  if (!site.is_valid() || !site.SchemeIsHTTPOrHTTPS() || site.has_username() ||
      site.has_password() || site.has_query() || site.has_ref() ||
      (origin != canonical.spec() && origin != canonical_text))
    return SHAAR_INVALID_ARGUMENT;
  auto *settings = HostContentSettingsMapFactory::GetForProfile(otr);
  if (!settings)
    return SHAAR_NOT_READY;
  if (set) {
    content_settings::SettingInfo info;
    const ContentSetting current = settings->GetContentSetting(
        site, site, ContentSettingsType::COOKIES, &info);
    if (current != CONTENT_SETTING_DEFAULT &&
        info.source != content_settings::SettingSource::kUser)
      return SHAAR_POLICY_BLOCKED;
    settings->SetContentSettingDefaultScope(
        site, site, ContentSettingsType::COOKIES,
        allow ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
  }
  content_settings::SettingInfo info;
  *allowed =
      settings->GetContentSetting(site, site, ContentSettingsType::COOKIES,
                                  &info) == CONTENT_SETTING_ALLOW;
  return SHAAR_OK;
}

bool PrivateSessionRegistry::IsLive(const Session* session) const {
  if (!session)
    return false;
  for (const auto& entry : sessions_) {
    if (entry.second == session)
      return true;
  }
  return false;
}

void PrivateSessionRegistry::Emit(const Session& session, EventState state) {
  if (event_sink_)
    event_sink_(session.profile_id, session.id, state);
}

void PrivateSessionRegistry::MaybeRetire(Session* session) {
  if (!session->closing || session->open_handles != 0 || session->children != 0)
    return;
  Emit(*session, EventState::kClosed);
  retired_ids_.insert(session->id);
  Profile* parent = session->parent;
  Profile* otr = session->otr;
  auto parent_sessions = parent_sessions_.find(parent);
  CHECK(parent_sessions != parent_sessions_.end());
  parent_sessions->second.erase(session->id);
  sessions_.erase(session->id);
  if (parent_sessions->second.empty()) {
    parent_sessions_.erase(parent_sessions);
    parent->RemoveObserver(this);
    TrackerProtection().RemoveProfile(otr);
    TrackerProtection().RemoveProfile(parent);
    // Closing the last Chromium private Browser may already have retired the
    // primary OTR profile. Do not pass its stale pointer back to ProfileImpl.
    if (parent->GetPrimaryOTRProfile(/*create_if_needed=*/false) == otr)
      parent->DestroyOffTheRecordProfile(otr);
  }
  session->parent = nullptr;
  session->otr = nullptr;
}

}  // namespace shaar

namespace shaar {

shaar_error_code ConfigurePrivateProfile(Profile* otr) {
  if (!otr || !otr->IsOffTheRecord())
    return SHAAR_WRONG_PROFILE;
  auto* settings = HostContentSettingsMapFactory::GetForProfile(otr);
  PrefService* prefs = otr->GetPrefs();
  if (!settings || !prefs)
    return SHAAR_NOT_READY;
  settings->SetDefaultContentSetting(ContentSettingsType::COOKIES,
                                     CONTENT_SETTING_BLOCK);
  prefs->SetBoolean(prefs::kHttpsOnlyModeEnabled, true);
  prefs->SetBoolean(prefs::kEnableReferrers, false);
  prefs->SetString(prefs::kWebRTCIPHandlingPolicy,
                   "disable_non_proxied_udp");
  prefs->SetList(prefs::kWebRTCIPHandlingUrl, base::ListValue());
  prefs->SetList(prefs::kWebRtcLocalIpsAllowedUrls, base::ListValue());
  prefs->SetBoolean("credentials_enable_service", false);
  prefs->SetBoolean("autofill.profile_enabled", false);
  prefs->SetBoolean("autofill.credit_card_enabled", false);
  const GURL probe("https://shaar-privacy.invalid/");
  return settings->GetContentSetting(probe, probe, ContentSettingsType::COOKIES) ==
                     CONTENT_SETTING_BLOCK &&
                 prefs->GetBoolean(prefs::kHttpsOnlyModeEnabled) &&
                 !prefs->GetBoolean(prefs::kEnableReferrers) &&
                 prefs->GetString(prefs::kWebRTCIPHandlingPolicy) ==
                     "disable_non_proxied_udp" &&
                 prefs->GetList(prefs::kWebRTCIPHandlingUrl).empty() &&
                 prefs->GetList(prefs::kWebRtcLocalIpsAllowedUrls).empty() &&
                 !prefs->GetBoolean("credentials_enable_service") &&
                 !prefs->GetBoolean("autofill.profile_enabled") &&
                 !prefs->GetBoolean("autofill.credit_card_enabled")
             ? SHAAR_OK
             : SHAAR_POLICY_BLOCKED;
}

std::string PrivateProfilePrivacyStatus(Profile* otr) {
  if (!otr || !otr->IsOffTheRecord())
    return {};
  auto* settings = HostContentSettingsMapFactory::GetForProfile(otr);
  PrefService* prefs = otr->GetPrefs();
  if (!settings || !prefs)
    return {};
  base::DictValue status;
  status.Set("offTheRecord", true);
  const GURL probe("https://shaar-privacy.invalid/");
  status.Set("globalCookies",
             settings->GetContentSetting(probe, probe, ContentSettingsType::COOKIES) ==
                     CONTENT_SETTING_BLOCK ? "block" : "other");
  status.Set("httpsOnly", prefs->GetBoolean(prefs::kHttpsOnlyModeEnabled));
  status.Set("referrersEnabled", prefs->GetBoolean(prefs::kEnableReferrers));
  status.Set("webRTCIPHandlingPolicy",
             prefs->GetString(prefs::kWebRTCIPHandlingPolicy));
  status.Set("webRTCPolicyExceptionCount",
             static_cast<int>(prefs->GetList(prefs::kWebRTCIPHandlingUrl).size()));
  status.Set("localIPExceptionCount",
             static_cast<int>(prefs->GetList(prefs::kWebRtcLocalIpsAllowedUrls).size()));
  status.Set("extensionsDisabled", PrivateExtensionsDisabled(otr));
  for (const char* key : {"credentials_enable_service", "autofill.profile_enabled",
                          "autofill.credit_card_enabled"}) {
    status.Set(std::string(key) + "Private", prefs->GetBoolean(key));
    status.Set(std::string(key) + "Normal",
               otr->GetOriginalProfile()->GetPrefs()->GetBoolean(key));
  }
  std::string json;
  if (!base::JSONWriter::Write(status, &json))
    return {};
  return json;
}

shaar_error_code OpenPrivateSessionHandler(
    void* context,
    Profile* parent,
    const std::string& profile_id,
    const std::string& session_id,
    PrivateSessionRegistry::Session** out) {
  if (!out)
    return SHAAR_INVALID_ARGUMENT;
  *out = nullptr;
  if (!context || !parent || profile_id.empty() || session_id.empty())
    return SHAAR_INVALID_ARGUMENT;
  if (parent->IsOffTheRecord() || parent->GetOriginalProfile() != parent)
    return SHAAR_WRONG_PROFILE;
  auto* sessions = static_cast<PrivateSessionRegistry*>(context);
  return sessions->Open(parent, profile_id, session_id, out);
}

shaar_error_code PrivateSessionScopePolicy(shaar_scope scope,
                                           shaar_operation operation) {
  if (scope.size < sizeof(shaar_scope))
    return SHAAR_INVALID_ARGUMENT;
  if ((scope.profile == nullptr) == (scope.private_session == nullptr))
    return SHAAR_INVALID_ARGUMENT;
  if (!scope.private_session)
    return SHAAR_OK;
  switch (operation) {
    case SHAAR_OP_DOWNLOAD_LIST:
    case SHAAR_OP_DOWNLOAD_DIRECTORY:
    case SHAAR_OP_BOOKMARK_TREE:
    case SHAAR_OP_BOOKMARK_APPLY:
    case SHAAR_OP_HISTORY_QUERY:
    case SHAAR_OP_HISTORY_INSERT:
    case SHAAR_OP_HISTORY_DELETE:
    case SHAAR_OP_PROFILE_DELETE:
    case SHAAR_OP_PROFILE_SET_STATE:
      return SHAAR_PRIVATE_DISALLOWED;
    default:
      return SHAAR_OK;
  }
}

shaar_error_code EmitPrivateSessionStateEvent(
    shaar_engine* engine,
    const std::string& profile_id,
    const std::string& session_id,
    PrivateSessionRegistry::EventState state) {
  const char* payload = nullptr;
  size_t payload_size = 0;
  switch (state) {
    case PrivateSessionRegistry::EventState::kOpened:
      payload = "{\"kind\":\"privateSession.opened\",\"schemaVersion\":1}";
      payload_size = sizeof("{\"kind\":\"privateSession.opened\",\"schemaVersion\":1}") - 1;
      break;
    case PrivateSessionRegistry::EventState::kClosing:
      payload = "{\"kind\":\"privateSession.closing\",\"schemaVersion\":1}";
      payload_size = sizeof("{\"kind\":\"privateSession.closing\",\"schemaVersion\":1}") - 1;
      break;
    case PrivateSessionRegistry::EventState::kClosed:
      payload = "{\"kind\":\"privateSession.closed\",\"schemaVersion\":1}";
      payload_size = sizeof("{\"kind\":\"privateSession.closed\",\"schemaVersion\":1}") - 1;
      break;
  }
  return EmitEvent(
      engine, SHAAR_EVENT_PRIVATE_SESSION,
      {profile_id.data(), profile_id.size()},
      {session_id.data(), session_id.size()}, {nullptr, 0}, {nullptr, 0},
      {payload, payload_size});
}

std::unique_ptr<PrivateSessionRegistry> CreatePrivateSessionRegistry(
    shaar_engine* engine) {
  return std::make_unique<PrivateSessionRegistry>(
      [engine](const std::string& profile_id, const std::string& session_id,
               PrivateSessionRegistry::EventState state) {
        EmitPrivateSessionStateEvent(engine, profile_id, session_id, state);
      });
}

shaar_error_code ClosePrivateSessionHandler(
    void* context,
    PrivateSessionRegistry::Session* session) {
  if (!context || !session)
    return SHAAR_INVALID_ARGUMENT;
  return static_cast<PrivateSessionRegistry*>(context)->Close(session)
             ? SHAAR_OK
             : SHAAR_NOT_FOUND;
}

}  // namespace shaar

namespace {

using Session = shaar::PrivateSessionRegistry::Session;
std::map<shaar_engine *, std::unique_ptr<shaar::PrivateSessionRegistry>>
    g_registries;
std::map<shaar_private_session *, shaar_engine *> g_handles;

shaar_error_code Result(shaar_error_code code, shaar_error *error) {
  if (error && error->size >= offsetof(shaar_error, code) + sizeof(error->code))
    error->code = code;
  return code;
}

shaar::PrivateSessionRegistry *RegistryFor(shaar_engine *engine) {
  auto found = g_registries.find(engine);
  return found == g_registries.end() ? nullptr : found->second.get();
}

class PrivateSessionServicesImpl final : public shaar::PrivateSessionServices {
public:
  bool Resolve(shaar_engine *engine, shaar_private_session *handle,
               Profile **parent, Profile **otr, std::string_view *profile_id,
               std::string_view *session_id) override {
    auto found = g_handles.find(handle);
    auto *registry = RegistryFor(engine);
    return found != g_handles.end() && found->second == engine && registry &&
           registry->Resolve(reinterpret_cast<Session *>(handle), parent, otr,
                             profile_id, session_id);
  }

  bool RetainChild(shaar_engine *engine,
                   shaar_private_session *handle) override {
    auto found = g_handles.find(handle);
    auto *registry = RegistryFor(engine);
    return found != g_handles.end() && found->second == engine && registry &&
           registry->RetainChild(reinterpret_cast<Session *>(handle));
  }

  bool ReleaseChild(shaar_engine *engine,
                    shaar_private_session *handle) override {
    auto found = g_handles.find(handle);
    auto *registry = RegistryFor(engine);
    return found != g_handles.end() && found->second == engine && registry &&
           registry->ReleaseChild(reinterpret_cast<Session *>(handle));
  }
};

PrivateSessionServicesImpl g_services;

} // namespace

extern "C" SHAAR_EXPORT shaar_error_code
shaar_private_session_open(shaar_profile *profile, shaar_bytes session_id,
                           shaar_private_session **out, shaar_error *error) {
  if (out)
    *out = nullptr;
  if (!pthread_main_np() || !out || !profile || !session_id.data ||
      !session_id.size)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  shaar_engine *engine = shaar::lifecycle::ActiveEngine();
  // Direct ABI calls can precede the first shaar_submit; register the
  // profile and private-session services before resolving either handle.
  (void)shaar::lifecycle::ModuleRegistry();
  auto *profiles = shaar::EngineContext().profile_services;
  if (!engine || !shaar::lifecycle::EngineIsReady(engine) || !profiles)
    return Result(SHAAR_NOT_READY, error);
  Profile *parent = profiles->ResolveProfile(engine, profile);
  const std::string_view profile_id = profiles->ProfileID(engine, profile);
  if (!parent || profile_id.empty())
    return Result(SHAAR_WRONG_PROFILE, error);
  auto &registry = g_registries[engine];
  if (!registry)
    registry = shaar::CreatePrivateSessionRegistry(engine);
  Session *session = nullptr;
  const shaar_error_code code =
      registry->Open(parent, std::string(profile_id),
                     std::string(session_id.data, session_id.size), &session);
  if (code != SHAAR_OK)
    return Result(code, error);
  auto *handle = reinterpret_cast<shaar_private_session *>(session);
  g_handles[handle] = engine;
  *out = handle;
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code
shaar_private_session_close(shaar_private_session *handle, shaar_error *error) {
  if (!pthread_main_np() || !handle)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = g_handles.find(handle);
  if (found == g_handles.end())
    return Result(SHAAR_NOT_FOUND, error);
  auto *registry = RegistryFor(found->second);
  if (!registry || !registry->Close(reinterpret_cast<Session *>(handle)))
    return Result(SHAAR_NOT_FOUND, error);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_private_session_cookie_setting(
    shaar_private_session *handle, shaar_bytes origin, int set, int allow,
    int *allowed, shaar_error *error) {
  if (!pthread_main_np() || !handle || !origin.data || !origin.size ||
      !allowed || (set != 0 && set != 1) || (allow != 0 && allow != 1))
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = g_handles.find(handle);
  if (found == g_handles.end())
    return Result(SHAAR_NOT_FOUND, error);
  Profile *parent = nullptr;
  Profile *otr = nullptr;
  if (!g_services.Resolve(found->second, handle, &parent, &otr, nullptr,
                          nullptr))
    return Result(SHAAR_NOT_FOUND, error);
  bool value = false;
  const shaar_error_code code = shaar::PrivateCookieSetting(
      otr, std::string_view(origin.data, origin.size), set != 0, allow != 0,
      &value);
  if (code == SHAAR_OK)
    *allowed = value ? 1 : 0;
  return Result(code, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_private_session_privacy_status(
    shaar_private_session *handle, char *json, size_t capacity,
    shaar_error *error) {
  if (!pthread_main_np() || !handle || !json || capacity == 0)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = g_handles.find(handle);
  if (found == g_handles.end())
    return Result(SHAAR_NOT_FOUND, error);
  Profile *otr = nullptr;
  if (!g_services.Resolve(found->second, handle, nullptr, &otr, nullptr,
                          nullptr))
    return Result(SHAAR_NOT_FOUND, error);
  const std::string status = shaar::PrivateProfilePrivacyStatus(otr);
  if (status.empty())
    return Result(SHAAR_NOT_READY, error);
  if (status.size() + 1 > capacity)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  std::memcpy(json, status.c_str(), status.size() + 1);
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_private_session_tracker_rules(
    shaar_private_session *handle, shaar_bytes revision,
    shaar_bytes domains_json, shaar_error *error) {
  if (!pthread_main_np() || !handle || !revision.data || !revision.size ||
      !domains_json.data || !domains_json.size ||
      domains_json.size > 4 * 1024 * 1024)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = g_handles.find(handle);
  if (found == g_handles.end())
    return Result(SHAAR_NOT_FOUND, error);
  Profile *parent = nullptr;
  if (!g_services.Resolve(found->second, handle, &parent, nullptr, nullptr,
                          nullptr))
    return Result(SHAAR_NOT_FOUND, error);
  auto value = base::JSONReader::Read(
      std::string_view(domains_json.data, domains_json.size),
      base::JSON_PARSE_RFC);
  if (!value || !value->is_list())
    return Result(SHAAR_INVALID_ARGUMENT, error);
  std::vector<std::string> domains;
  for (const auto &domain : value->GetList()) {
    if (!domain.is_string())
      return Result(SHAAR_INVALID_ARGUMENT, error);
    domains.push_back(domain.GetString());
  }
  return Result(shaar::TrackerProtection().SetRules(
                    parent, std::string(revision.data, revision.size), domains),
                error);
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_private_session_tracker_status(
    shaar_private_session *handle, char *revision, size_t revision_capacity,
    int *domain_count, int *blocked_requests, shaar_error *error) {
  if (!pthread_main_np() || !handle || !revision || revision_capacity < 201 ||
      !domain_count || !blocked_requests)
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = g_handles.find(handle);
  if (found == g_handles.end())
    return Result(SHAAR_NOT_FOUND, error);
  Profile *otr = nullptr;
  if (!g_services.Resolve(found->second, handle, nullptr, &otr, nullptr,
                          nullptr))
    return Result(SHAAR_NOT_FOUND, error);
  const auto status = shaar::TrackerProtection().Status(otr);
  if (!status.enabled)
    return Result(SHAAR_NOT_READY, error);
  std::memcpy(revision, status.revision.c_str(), status.revision.size() + 1);
  *domain_count = status.domain_count;
  *blocked_requests = status.blocked_requests;
  return Result(SHAAR_OK, error);
}

extern "C" SHAAR_EXPORT shaar_error_code
shaar_private_session_tracker_allowance(shaar_private_session *handle,
                                        shaar_bytes origin, int set, int allow,
                                        int *allowed, shaar_error *error) {
  if (!pthread_main_np() || !handle || !origin.data || !origin.size ||
      !allowed || (set != 0 && set != 1) || (allow != 0 && allow != 1))
    return Result(SHAAR_INVALID_ARGUMENT, error);
  auto found = g_handles.find(handle);
  if (found == g_handles.end())
    return Result(SHAAR_NOT_FOUND, error);
  Profile *otr = nullptr;
  if (!g_services.Resolve(found->second, handle, nullptr, &otr, nullptr,
                          nullptr))
    return Result(SHAAR_NOT_FOUND, error);
  std::string site(origin.data, origin.size);
  if (set) {
    const auto code = shaar::TrackerProtection().SetAllowance(otr, site, allow);
    if (code != SHAAR_OK)
      return Result(code, error);
  } else if (!shaar::ValidPrivateTrackerOrigin(site)) {
    return Result(SHAAR_INVALID_ARGUMENT, error);
  }
  *allowed = shaar::TrackerProtection().Allowance(otr, site) ? 1 : 0;
  return Result(SHAAR_OK, error);
}

extern "C" void shaar_private_sessions_register(
    ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  static const shaar::PrivateSessionModuleHandlers handlers{
      .open = &shaar::OpenPrivateSessionHandler,
      .close = &shaar::ClosePrivateSessionHandler,
      .scope_policy = &shaar::PrivateSessionScopePolicy};
  registry->RegisterModule(SHAAR_MODULE_PRIVATE_SESSIONS, &handlers);
  shaar::SetPrivateSessionServices(&g_services);
}
