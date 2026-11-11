// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/site_data/shaar_site_data.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <optional>
#include <pthread.h>
#include <stddef.h>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/custom_handlers/protocol_handler_registry_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/browser/cookie_settings.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/common/pref_names.h"
#include "components/custom_handlers/protocol_handler.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/ssl_status.h"
#include "content/public/browser/web_contents.h"
#include "net/cert/cert_status_flags.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

constexpr size_t kMaxArguments = 64 * 1024;

using Dict = base::DictValue;

shaar_error_code Fail(shaar_error* error,
                      shaar_error_code code,
                      const char* message) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >= offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, strlen(message)};
  }
  return code;
}

bool OnlyKeys(const Dict& dict, std::initializer_list<std::string_view> keys) {
  for (const auto& item : dict) {
    if (std::find(keys.begin(), keys.end(), item.first) == keys.end())
      return false;
  }
  return true;
}

std::optional<Dict> Parse(shaar_bytes bytes) {
  if (!bytes.data || !bytes.size || bytes.size > kMaxArguments)
    return std::nullopt;
  auto value = base::JSONReader::Read(std::string_view(bytes.data, bytes.size), base::JSON_PARSE_RFC);
  if (!value || !value->is_dict())
    return std::nullopt;
  Dict dict = std::move(value->GetDict());
  if (dict.FindInt("schemaVersion") != 1)
    return std::nullopt;
  return dict;
}

bool ValidOrigin(std::string_view text, GURL* origin) {
  if (text.empty() || text.size() > 4096 || text.find('\0') != std::string_view::npos)
    return false;
  GURL parsed{std::string(text)};
  if (!parsed.is_valid() || !parsed.SchemeIsHTTPOrHTTPS() ||
      parsed.has_username() || parsed.has_password() || parsed.has_ref() ||
      parsed.has_query() || parsed.path() != "/")
    return false;
  *origin = parsed;
  return true;
}

struct SettingType {
  std::string_view name;
  ContentSettingsType type;
};

constexpr SettingType kSettingTypes[] = {
    {"microphone", ContentSettingsType::MEDIASTREAM_MIC},
    {"camera", ContentSettingsType::MEDIASTREAM_CAMERA},
    {"location", ContentSettingsType::GEOLOCATION},
    {"notifications", ContentSettingsType::NOTIFICATIONS},
    {"popups", ContentSettingsType::POPUPS},
    {"sound", ContentSettingsType::SOUND},
    {"midi", ContentSettingsType::MIDI_SYSEX},
};

std::optional<ContentSettingsType> TypeForName(std::string_view name) {
  for (const auto& entry : kSettingTypes) {
    if (entry.name == name &&
        content_settings::ContentSettingsRegistry::GetInstance()->Get(entry.type))
      return entry.type;
  }
  return std::nullopt;
}

std::optional<ContentSetting> SettingForName(std::string_view value) {
  if (value == "allow") return CONTENT_SETTING_ALLOW;
  if (value == "block") return CONTENT_SETTING_BLOCK;
  if (value == "ask") return CONTENT_SETTING_ASK;
  if (value == "default") return CONTENT_SETTING_DEFAULT;
  return std::nullopt;
}

std::string_view NameForSetting(ContentSetting value) {
  switch (value) {
    case CONTENT_SETTING_ALLOW: return "allow";
    case CONTENT_SETTING_BLOCK: return "block";
    case CONTENT_SETTING_ASK: return "ask";
    default: return "ask";
  }
}

void ReplyLater(shaar_reply_fn callback, void* context, shaar_request_id id,
                shaar_error_code code, std::string json = {}) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
          [](shaar_reply_fn callback, void* context, shaar_request_id id,
             shaar_error_code code, std::string json) {
            shaar_result result{};
            result.size = sizeof(result);
            result.request_id = id;
            result.error.size = sizeof(result.error);
            result.error.code = code;
            result.payload_json = {json.data(), json.size()};
            callback(context, &result);
          }, callback, context, id, code, std::move(json)));
}

Profile* ResolveRegular(shaar::ShaarEngineContext* context,
                        shaar_engine* engine,
                        shaar_scope scope,
                        shaar_error* error) {
  if (scope.private_session)
    return nullptr;
  if (scope.size < sizeof(shaar_scope) || !scope.profile)
    return nullptr;
  if (!context || !context->profile_services) {
    Fail(error, SHAAR_NOT_READY, "profile services are unavailable");
    return nullptr;
  }
  Profile* profile = context->profile_services->ResolveProfile(engine, scope.profile);
  if (!profile) {
    Fail(error, SHAAR_NOT_FOUND, "profile is not available");
    return nullptr;
  }
  if (profile->IsOffTheRecord()) {
    Fail(error, SHAAR_PRIVATE_DISALLOWED, "regular profile required");
    return nullptr;
  }
  return profile;
}

shaar_error_code ReturnPayload(shaar_reply_fn reply, void* context,
                               shaar_request_id request_id, Dict payload) {
  std::string json;
  base::JSONWriter::Write(base::Value(std::move(payload)), &json);
  ReplyLater(reply, context, request_id, SHAAR_OK, std::move(json));
  return SHAAR_OK;
}

class ClearObserver final : public content::BrowsingDataRemover::Observer {
 public:
  ClearObserver(shaar_reply_fn reply, void* context, shaar_request_id request_id,
                shaar_engine* engine, std::string profile_id,
                std::string session_id,
                std::string response)
      : reply_(reply), context_(context), request_id_(request_id),
        engine_(engine), profile_id_(std::move(profile_id)),
        session_id_(std::move(session_id)),
        response_(std::move(response)) {}
  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    shaar_result result{};
    result.size = sizeof(result);
    result.request_id = request_id_;
    result.error.size = sizeof(result.error);
    result.error.code = failed ? SHAAR_CHROMIUM_ERROR : SHAAR_OK;
    result.payload_json = failed ? shaar_bytes{nullptr, 0}
                                 : shaar_bytes{response_.data(), response_.size()};
    const std::string event = failed
        ? "{\"kind\":\"clearFailed\",\"schemaVersion\":1}"
        : "{\"kind\":\"clearCompleted\",\"schemaVersion\":1}";
    shaar::EmitEvent(engine_, SHAAR_EVENT_SITE_DATA,
        {profile_id_.data(), profile_id_.size()},
        {session_id_.data(), session_id_.size()}, {},
        {nullptr, 0}, {event.data(), event.size()});
    auto callback = reply_;
    void* context = context_;
    callback(context, &result);
    delete this;
  }

 private:
  shaar_reply_fn reply_;
  void* context_;
  shaar_request_id request_id_;
  shaar_engine* engine_;
  std::string profile_id_;
  std::string session_id_;
  std::string response_;
};

shaar_error_code Clear(Profile* profile, const GURL* origin, uint64_t mask,
                       base::Time begin, shaar_engine* engine,
                       std::string profile_id, std::string session_id,
                       shaar_reply_fn reply, void* context,
                       shaar_request_id request_id, shaar_error* error) {
  auto* remover = profile->GetBrowsingDataRemover();
  if (!remover)
    return Fail(error, SHAAR_NOT_READY, "browsing data remover is unavailable");
  std::string response;
  Dict payload;
  payload.Set("schemaVersion", 1);
  payload.Set("complete", true);
  if (!origin) {
    base::ListValue types;
    if (mask & content::BrowsingDataRemover::DATA_TYPE_CACHE)
      types.Append("cache");
    if (mask & chrome_browsing_data_remover::DATA_TYPE_SITE_DATA)
      types.Append("siteData");
    payload.Set("clearedTypes", std::move(types));
  }
  base::JSONWriter::Write(base::Value(std::move(payload)), &response);
  auto* observer = new ClearObserver(reply, context, request_id, engine,
                                     std::move(profile_id),
                                     std::move(session_id), std::move(response));
  if (origin) {
    auto filter = content::BrowsingDataFilterBuilder::Create(
        content::BrowsingDataFilterBuilder::Mode::kDelete);
    filter->AddOrigin(url::Origin::Create(*origin));
    remover->RemoveWithFilterAndReply(begin, base::Time::Max(), mask,
        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB |
            content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB,
        std::move(filter), observer);
  } else {
    remover->RemoveAndReply(begin, base::Time::Max(), mask,
        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB |
            content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB,
        observer);
  }
  return SHAAR_OK;
}

custom_handlers::ProtocolHandlerRegistry* ProtocolHandlers(Profile* profile) {
  if (!profile)
    return nullptr;
  return ProtocolHandlerRegistryFactory::GetForBrowserContext(profile);
}

bool HandlerMatchesOrigin(const custom_handlers::ProtocolHandler& handler,
                          const GURL& origin) {
  return url::Origin::Create(handler.url())
      .IsSameOriginWith(url::Origin::Create(origin));
}

bool OriginHasUserProtocolHandler(Profile* profile, const GURL& origin) {
  auto* registry = ProtocolHandlers(profile);
  if (!registry)
    return false;
  const auto handlers =
      registry->GetUserDefinedHandlers(base::Time::Min(), base::Time::Max());
  for (const auto& handler : handlers) {
    if (HandlerMatchesOrigin(handler, origin))
      return true;
  }
  return false;
}

int RemoveUserProtocolHandlers(Profile* profile, const GURL& origin) {
  auto* registry = ProtocolHandlers(profile);
  if (!registry)
    return 0;
  const auto handlers =
      registry->GetUserDefinedHandlers(base::Time::Min(), base::Time::Max());
  int removed = 0;
  for (const auto& handler : handlers) {
    if (!HandlerMatchesOrigin(handler, origin))
      continue;
    registry->RemoveHandler(handler);
    ++removed;
  }
  return removed;
}

void AppendProtocolHandlerOrigins(Profile* profile,
                                  std::vector<std::string>* origins) {
  auto* registry = ProtocolHandlers(profile);
  if (!registry || !origins)
    return;
  const auto handlers =
      registry->GetUserDefinedHandlers(base::Time::Min(), base::Time::Max());
  for (const auto& handler : handlers) {
    const GURL& url = handler.url();
    if (!url.SchemeIsHTTPOrHTTPS())
      continue;
    origins->push_back(url::Origin::Create(url).Serialize());
  }
}

}  // namespace

shaar_error_code HandleSiteDataOperation(
    shaar::ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, shaar_operation operation,
    shaar_bytes bytes,
    shaar_request_id request_id, shaar_reply_fn reply, void* reply_context,
    shaar_error* error) {
  if (!reply || !request_id)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "reply and request ID are required");
  if ((scope.profile == nullptr) == (scope.private_session == nullptr))
    return Fail(error, SHAAR_INVALID_ARGUMENT, "exactly one site-data scope is required");
  Profile* profile = nullptr;
  std::string profile_id;
  std::string session_id;
  if (scope.private_session) {
    if (!context || !context->private_sessions)
      return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "private-session profile resolver is not installed");
    Profile* parent = nullptr;
    std::string_view resolved_profile_id;
    std::string_view resolved_session_id;
    if (!context->private_sessions->Resolve(
            engine, scope.private_session, &parent, &profile,
            &resolved_profile_id, &resolved_session_id) ||
        !parent) {
      return Fail(error, SHAAR_WRONG_SESSION,
                  "private session is unavailable");
    }
    profile_id = std::string(resolved_profile_id);
    session_id = std::string(resolved_session_id);
    if (!profile || !profile->IsOffTheRecord() || profile_id.empty() ||
        session_id.empty())
      return Fail(error, SHAAR_WRONG_SESSION, "private session is unavailable");
  } else {
    profile = ResolveRegular(context, engine, scope, error);
    if (profile && context && context->profile_services)
      profile_id = std::string(context->profile_services->ProfileID(
          engine, scope.profile));
  }
  if (!profile)
    return error && error->code ? error->code : SHAAR_INVALID_ARGUMENT;
  auto args = Parse(bytes);
  if (!args)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid site-data request schema");
  auto* settings = HostContentSettingsMapFactory::GetForProfile(profile);
  if (!settings)
    return Fail(error, SHAAR_NOT_READY, "content settings are unavailable");
  if (profile_id.empty())
    return Fail(error, SHAAR_NOT_FOUND, "profile ID is unavailable");

  if (operation == SHAAR_OP_SITE_SETTINGS_GET ||
      operation == SHAAR_OP_SITE_SETTINGS_SET ||
      operation == SHAAR_OP_SITE_SETTINGS_RESET ||
      operation == SHAAR_OP_SITE_DATA_CLEAR) {
    const std::string* raw_origin = args->FindString("origin");
    GURL origin;
    if (!raw_origin || !ValidOrigin(*raw_origin, &origin))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "origin must be an exact HTTP(S) origin");

    if (operation == SHAAR_OP_SITE_SETTINGS_GET) {
      if (!OnlyKeys(*args, {"schemaVersion", "origin"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown site settings fields");
      Dict values;
      for (const auto& entry : kSettingTypes) {
        auto type = TypeForName(entry.name);
        if (!type) continue;
        content_settings::SettingInfo info;
        const ContentSetting value = settings->GetContentSetting(origin, origin, *type, &info);
        Dict item;
        item.Set("value", std::string(NameForSetting(value)));
        item.Set("isDefault", value == CONTENT_SETTING_DEFAULT);
        values.Set(std::string(entry.name), std::move(item));
      }
      Dict handlers;
      const bool registered = OriginHasUserProtocolHandler(profile, origin);
      handlers.Set("value", registered ? std::string("allow") : std::string("ask"));
      handlers.Set("isDefault", !registered);
      values.Set("protocolHandlers", std::move(handlers));
      Dict payload;
      payload.Set("schemaVersion", 1);
      payload.Set("settings", std::move(values));
      return ReturnPayload(reply, reply_context, request_id, std::move(payload));
    }
    if (operation == SHAAR_OP_SITE_SETTINGS_SET) {
      if (!OnlyKeys(*args, {"schemaVersion", "origin", "type", "value"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown setting fields");
      const std::string* raw_type = args->FindString("type");
      const std::string* raw_value = args->FindString("value");
      auto type = raw_type ? TypeForName(*raw_type) : std::nullopt;
      auto value = raw_value ? SettingForName(*raw_value) : std::nullopt;
      if (!type || !value)
        return Fail(error, SHAAR_INVALID_ARGUMENT, "unsupported setting type or value");
      if (*value != CONTENT_SETTING_DEFAULT &&
          !content_settings::ContentSettingsRegistry::GetInstance()->Get(*type))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "setting type is not registered");
      content_settings::SettingInfo current_info;
      const ContentSetting current =
          settings->GetContentSetting(origin, origin, *type, &current_info);
      if (current != CONTENT_SETTING_DEFAULT &&
          current_info.source != content_settings::SettingSource::kUser)
        return Fail(error, SHAAR_POLICY_BLOCKED, "setting is managed by policy");
      settings->SetContentSettingDefaultScope(origin, origin, *type, *value);
      const std::string event = "{\"kind\":\"settingsChanged\",\"schemaVersion\":1}";
      shaar::EmitEvent(engine, SHAAR_EVENT_SITE_DATA,
          {profile_id.data(), profile_id.size()},
          {session_id.data(), session_id.size()}, {}, {},
          {event.data(), event.size()});
      Dict payload;
      payload.Set("schemaVersion", 1);
      payload.Set("value", std::string(NameForSetting(*value)));
      payload.Set("isDefault", *value == CONTENT_SETTING_DEFAULT);
      return ReturnPayload(reply, reply_context, request_id, std::move(payload));
    }
    if (operation == SHAAR_OP_SITE_SETTINGS_RESET) {
      if (!OnlyKeys(*args, {"schemaVersion", "origin"}))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown reset fields");
      std::vector<ContentSettingsType> reset_types;
      for (const auto& entry : kSettingTypes) {
        auto type = TypeForName(entry.name);
        if (!type) continue;
        content_settings::SettingInfo info;
        const auto current = settings->GetContentSetting(origin, origin, *type, &info);
        if (current != CONTENT_SETTING_DEFAULT &&
            info.source != content_settings::SettingSource::kUser)
          return Fail(error, SHAAR_POLICY_BLOCKED, "site setting is managed by policy");
        if (current != CONTENT_SETTING_DEFAULT) {
          reset_types.push_back(*type);
        }
      }
      const int removed_handlers = RemoveUserProtocolHandlers(profile, origin);
      for (const auto type : reset_types)
        settings->SetContentSettingDefaultScope(origin, origin, type,
                                                CONTENT_SETTING_DEFAULT);
      if (!reset_types.empty() || removed_handlers > 0) {
        const std::string event = "{\"kind\":\"settingsChanged\",\"schemaVersion\":1}";
        shaar::EmitEvent(engine, SHAAR_EVENT_SITE_DATA,
            {profile_id.data(), profile_id.size()},
            {session_id.data(), session_id.size()}, {}, {},
            {event.data(), event.size()});
      }
      Dict payload;
      payload.Set("schemaVersion", 1);
      payload.Set("resetCount",
                  static_cast<int>(reset_types.size()) + removed_handlers);
      return ReturnPayload(reply, reply_context, request_id, std::move(payload));
    }
    if (!OnlyKeys(*args, {"schemaVersion", "origin", "includeCookies", "includeStorage"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown site-data fields");
    bool include_cookies = true;
    bool include_storage = true;
    if (const auto* value = args->Find("includeCookies")) {
      if (!value->is_bool())
        return Fail(error, SHAAR_INVALID_ARGUMENT, "includeCookies must be boolean");
      include_cookies = value->GetBool();
    }
    if (const auto* value = args->Find("includeStorage")) {
      if (!value->is_bool())
        return Fail(error, SHAAR_INVALID_ARGUMENT, "includeStorage must be boolean");
      include_storage = value->GetBool();
    }
    if (!include_cookies && !include_storage)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "at least one site-data class is required");
    const uint64_t mask = include_cookies && include_storage
        ? chrome_browsing_data_remover::DATA_TYPE_SITE_DATA
        : include_cookies
            ? content::BrowsingDataRemover::DATA_TYPE_COOKIES
            : chrome_browsing_data_remover::DATA_TYPE_SITE_DATA &
                  ~content::BrowsingDataRemover::DATA_TYPE_COOKIES;
    return Clear(profile, &origin, mask, base::Time(), engine, profile_id,
                 session_id,
                 reply, reply_context, request_id, error);
  }

  if (operation == SHAAR_OP_SITE_SETTINGS_ORIGINS) {
    if (!OnlyKeys(*args, {"schemaVersion"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown origins fields");
    std::vector<std::string> origins;
    for (const auto& entry : kSettingTypes) {
      auto type = TypeForName(entry.name);
      if (!type) continue;
      for (const auto& setting : settings->GetSettingsForOneType(*type)) {
        if (content_settings::GetSettingSourceFromProviderType(setting.source) !=
            content_settings::SettingSource::kUser)
          continue;
        const std::string primary = setting.primary_pattern.ToString();
        GURL url(primary);
        if (url.is_valid() && url.SchemeIsHTTPOrHTTPS())
          origins.push_back(url::Origin::Create(url).Serialize());
      }
    }
    AppendProtocolHandlerOrigins(profile, &origins);
    std::sort(origins.begin(), origins.end());
    origins.erase(std::unique(origins.begin(), origins.end()), origins.end());
    base::ListValue list;
    for (const auto& origin : origins) list.Append(origin);
    Dict payload;
    payload.Set("schemaVersion", 1);
    payload.Set("origins", std::move(list));
    return ReturnPayload(reply, reply_context, request_id, std::move(payload));
  }

  if (operation == SHAAR_OP_BROWSING_DATA_CLEAR) {
    if (scope.private_session)
      return Fail(error, SHAAR_PRIVATE_DISALLOWED,
                  "profile browsing-data clearing is regular-only");
    if (!OnlyKeys(*args, {"schemaVersion", "types", "sinceUnixMs"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown browsing-data fields");
    const base::ListValue* types = args->FindList("types");
    if (!types || types->empty() || types->size() > 2)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "types must be a nonempty list");
    uint64_t mask = 0;
    for (const auto& type : *types) {
      if (!type.is_string())
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid browsing-data type");
      if (type.GetString() == "cache") mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
      else if (type.GetString() == "siteData") mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
      else return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown browsing-data type");
    }
    const auto* since = args->Find("sinceUnixMs");
    base::Time begin;
    if (since) {
      const double milliseconds = since->is_int()
          ? since->GetInt()
          : since->is_double() ? since->GetDouble() : -1;
      if (!std::isfinite(milliseconds) || milliseconds < 0 ||
          std::floor(milliseconds) != milliseconds ||
          milliseconds > static_cast<double>(std::numeric_limits<int64_t>::max()))
        return Fail(error, SHAAR_INVALID_ARGUMENT, "invalid sinceUnixMs");
      begin = base::Time::UnixEpoch() +
              base::Milliseconds(static_cast<int64_t>(milliseconds));
    }
    return Clear(profile, nullptr, mask, begin, engine, profile_id, session_id,
                 reply, reply_context, request_id, error);
  }

  if (operation == SHAAR_OP_SITE_COOKIES_CLEAR) {
    if (!OnlyKeys(*args, {"schemaVersion", "origin"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown selected-cookie fields");
    const std::string* raw_origin = args->FindString("origin");
    GURL origin;
    if (!raw_origin || !ValidOrigin(*raw_origin, &origin))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "origin must be an exact HTTP(S) origin");
    if (!window || !tab || !context->browser_tabs)
      return Fail(error, SHAAR_INVALID_ARGUMENT, "selected tab and window are required");
    Browser* browser = context->browser_tabs->FindBrowser(engine, window);
    content::WebContents* contents =
        context->browser_tabs->FindWebContents(engine, window, tab);
    if (!browser || !contents || !browser->tab_strip_model())
      return Fail(error, SHAAR_NOT_FOUND, "selected tab is no longer available");
    if (browser->tab_strip_model()->GetActiveWebContents() != contents)
      return Fail(error, SHAAR_CONFLICT, "tab is no longer selected");
    if (contents->GetBrowserContext() != profile)
      return Fail(error, SHAAR_WRONG_PROFILE, "selected tab belongs to another profile");
    const GURL current = contents->GetLastCommittedURL();
    if (!current.SchemeIsHTTPOrHTTPS() ||
        url::Origin::Create(current) != url::Origin::Create(origin))
      return Fail(error, SHAAR_CONFLICT, "selected tab origin has changed");
    return Clear(profile, &origin, content::BrowsingDataRemover::DATA_TYPE_COOKIES,
                 base::Time(), engine, profile_id, session_id,
                 reply, reply_context,
                 request_id, error);
  }

  if (operation == SHAAR_OP_THIRD_PARTY_COOKIES_GET ||
      operation == SHAAR_OP_THIRD_PARTY_COOKIES_SET) {
    if (scope.private_session)
      return Fail(error, SHAAR_PRIVATE_DISALLOWED,
                  "third-party cookie policy is profile-wide");
    const bool setting = operation == SHAAR_OP_THIRD_PARTY_COOKIES_SET;
    if (!OnlyKeys(*args, setting ? std::initializer_list<std::string_view>{
                                      "schemaVersion", "blocked"}
                                : std::initializer_list<std::string_view>{
                                      "schemaVersion"}))
      return Fail(error, SHAAR_INVALID_ARGUMENT, "unknown cookie-policy fields");
    PrefService* prefs = profile->GetPrefs();
    const PrefService::Preference* preference =
        prefs ? prefs->FindPreference(prefs::kCookieControlsMode) : nullptr;
    if (!preference)
      return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY,
                  "cookie controls preference is not registered");
    const bool managed = preference->IsManaged();
    bool blocked = prefs->GetInteger(prefs::kCookieControlsMode) ==
        static_cast<int>(content_settings::CookieControlsMode::kBlockThirdParty);
    if (setting) {
      const auto* raw = args->Find("blocked");
      if (!raw || !raw->is_bool())
        return Fail(error, SHAAR_INVALID_ARGUMENT, "blocked must be boolean");
      if (managed)
        return Fail(error, SHAAR_POLICY_BLOCKED, "cookie policy is managed");
      blocked = raw->GetBool();
      prefs->SetInteger(prefs::kCookieControlsMode,
          static_cast<int>(blocked
              ? content_settings::CookieControlsMode::kBlockThirdParty
              : content_settings::CookieControlsMode::kOff));
      const std::string event =
          "{\"kind\":\"thirdPartyCookiePolicyChanged\",\"schemaVersion\":1}";
      shaar::EmitEvent(engine, SHAAR_EVENT_SITE_DATA,
          {profile_id.data(), profile_id.size()}, {}, {}, {},
          {event.data(), event.size()});
    }
    Dict payload;
    payload.Set("schemaVersion", 1);
    payload.Set("blocked", blocked);
    payload.Set("managed", managed);
    return ReturnPayload(reply, reply_context, request_id, std::move(payload));
  }
  return Fail(error, SHAAR_UNSUPPORTED_CAPABILITY, "unsupported site-data operation");
}

bool IsValidSiteDataOriginForTesting(std::string_view value) {
  GURL origin;
  return ValidOrigin(value, &origin);
}

std::string SiteSecurityLevelForTesting(std::string_view raw_url,
                                        bool certificate_error) {
  GURL url{std::string(raw_url)};
  if (!url.SchemeIsHTTPOrHTTPS())
    return "unavailable";
  if (certificate_error)
    return "certificateError";
  return url.SchemeIs("https") ? "secure" : "insecure";
}

extern "C" SHAAR_EXPORT shaar_error_code shaar_site_security_info(
    shaar_engine *engine, shaar_scope scope, shaar_window *window,
    shaar_tab *tab, shaar_bytes *out_json, shaar_error *error) {
  if (!pthread_main_np() || !engine || !window || !tab || !out_json ||
      scope.size < sizeof(shaar_scope) || !scope.profile ||
      scope.private_session)
    return Fail(error, SHAAR_INVALID_ARGUMENT, "selected regular tab required");
  auto &context = shaar::EngineContext();
  if (!context.profile_services || !context.browser_tabs)
    return Fail(error, SHAAR_NOT_READY, "site security services unavailable");
  Profile *profile =
      context.profile_services->ResolveProfile(engine, scope.profile);
  Browser *browser = context.browser_tabs->FindBrowser(engine, window);
  content::WebContents *contents =
      context.browser_tabs->FindWebContents(engine, window, tab);
  if (!profile || !browser || !contents ||
      contents->GetBrowserContext() != profile || !browser->tab_strip_model())
    return Fail(error, SHAAR_WRONG_PROFILE,
                "tab is outside the regular profile");
  if (browser->tab_strip_model()->GetActiveWebContents() != contents)
    return Fail(error, SHAAR_CONFLICT, "tab is no longer selected");
  const GURL &url = contents->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS())
    return Fail(error, SHAAR_INVALID_ARGUMENT, "tab has no web origin");
  content::NavigationEntry *entry =
      contents->GetController().GetLastCommittedEntry();
  const bool certificate_error =
      entry && net::IsCertStatusError(entry->GetSSL().cert_status);
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("origin", url::Origin::Create(url).Serialize());
  payload.Set("level",
              SiteSecurityLevelForTesting(url.spec(), certificate_error));
  static thread_local std::string response;
  base::JSONWriter::Write(base::Value(std::move(payload)), &response);
  *out_json = {response.data(), response.size()};
  return SHAAR_OK;
}
