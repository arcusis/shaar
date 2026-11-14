// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

#include <stddef.h>
#include <string.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "base/version.h"
#include "chrome/browser/extensions/component_loader.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_service.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/extensions/shaar_extension_install.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/extensions/shaar_extension_install.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/pending_extension_manager.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_urls.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/description_info.h"
#include "extensions/common/permissions/permissions_data.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "url/gurl.h"

namespace {

shaar_error_code Fail(shaar_error_code code,
                      const char* message,
                      shaar_error* error) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >=
        offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, strlen(message)};
  }
  return code;
}

struct ReplyState {
  shaar_reply_fn callback;
  void* context;
  shaar_request_id request_id;
};

void ReplyLater(ReplyState state, shaar_error_code code, std::string payload) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](ReplyState state, shaar_error_code code, std::string payload) {
            if (!state.callback)
              return;
            shaar_result result = {};
            result.size = sizeof(result);
            result.request_id = state.request_id;
            result.error.size = sizeof(result.error);
            result.error.code = code;
            result.payload_json = {payload.data(), payload.size()};
            state.callback(state.context, &result);
          },
          state, code, std::move(payload)));
}

bool HasOnlyKeys(const base::DictValue& dict,
                 std::initializer_list<const char*> keys) {
  for (const auto& entry : dict) {
    bool found = false;
    for (const char* allowed : keys) {
      if (entry.first == allowed) {
        found = true;
        break;
      }
    }
    if (!found)
      return false;
  }
  return true;
}

bool ParseArgs(shaar_bytes args, base::DictValue* dict) {
  if (!args.data || !args.size || !dict)
    return false;
  auto parsed = base::JSONReader::Read(std::string_view(args.data, args.size),
                                       base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return false;
  *dict = std::move(parsed->GetDict());
  const auto version = dict->FindInt("schemaVersion");
  return version && *version == 1;
}

bool ValidExtensionId(const std::string& id) {
  return id.size() == 32 &&
         std::all_of(id.begin(), id.end(), [](char character) {
           return character >= 'a' && character <= 'p';
         });
}

bool IsRegularExtension(const extensions::Extension* extension,
                        content::BrowserContext*) {
  return extension && extension->is_extension();
}

bool ValidInstallSource(const base::DictValue& input) {
  const std::string* source = input.FindString("source");
  if (!source)
    return false;
  if (*source == "sharedHome") {
    const std::string* version = input.FindString("approvedVersion");
    return HasOnlyKeys(input, {"schemaVersion", "action", "extensionId",
                               "source", "approvedVersion"}) &&
           version && base::Version(*version).IsValid();
  }
  return (*source == "webStore" || *source == "unpacked") &&
         HasOnlyKeys(input,
                     {"schemaVersion", "action", "extensionId", "source"});
}

std::optional<double> Number(const base::DictValue& input, const char* key) {
  if (auto value = input.FindDouble(key))
    return value;
  if (auto value = input.FindInt(key))
    return static_cast<double>(*value);
  return std::nullopt;
}

std::optional<std::string> EncodeList(Profile* profile,
                                      extensions::ExtensionRegistry* registry) {
  auto* extension_system = extensions::ExtensionSystem::Get(profile);
  auto* service =
      extension_system ? extension_system->extension_service() : nullptr;
  base::ListValue entries;
  const auto installed = registry->GenerateInstalledExtensionsSet();
  for (const auto& extension : installed) {
    // Components such as Chromium PDF are implementation details, not apps
    // installed by the Shaar user. Keep them enabled inside Chromium.
    if (!shaar::extensions_host::ShouldListLocation(extension->location()))
      continue;
    base::DictValue row;
    row.Set("id", extension->id());
    row.Set("name", extension->name());
    row.Set("version", extension->version().GetString());
    row.Set("fromWebStore", extension->from_webstore());
    row.Set("description",
            extensions::DescriptionInfo::GetDescription(*extension));
    base::ListValue api_permissions;
    base::ListValue host_permissions;
    const auto& active = extension->permissions_data()->active_permissions();
    for (const auto& permission : active.GetAPIsAsStrings())
      api_permissions.Append(permission);
    for (const auto& pattern : active.explicit_hosts())
      host_permissions.Append(pattern.GetAsString());
    row.Set("permissions", std::move(api_permissions));
    row.Set("hostPermissions", std::move(host_permissions));
    row.Set("enabled", registry->GetExtensionById(
                           extension->id(),
                           extensions::ExtensionRegistry::ENABLED) != nullptr);
    row.Set("mayDisable", service && service->UserCanDisableInstalledExtension(
                                         extension->id()));
    row.Set("incognitoEnabled",
            extensions::util::IsIncognitoEnabled(extension.get(), profile));
    row.Set("source", static_cast<int>(extension->location()));
    entries.Append(std::move(row));
  }
  base::DictValue result;
  result.Set("schemaVersion", 1);
  result.Set("extensions", std::move(entries));
  std::string json;
  if (!base::JSONWriter::Write(base::Value(std::move(result)), &json))
    return std::nullopt;
  return json;
}

}  // namespace

namespace shaar::extensions_host {
bool ShouldListLocation(extensions::mojom::ManifestLocation location) {
  return !extensions::Manifest::IsComponentLocation(location);
}
}  // namespace shaar::extensions_host

bool SharedHomeVersionSatisfied(std::string_view installed,
                                std::string_view approved) {
  base::Version installed_version{std::string(installed)};
  base::Version approved_version{std::string(approved)};
  return installed_version.IsValid() && approved_version.IsValid() &&
         installed_version.CompareTo(approved_version) >= 0;
}

shaar_error_code HandleExtensionsOperation(shaar::ShaarEngineContext* context,
                                           shaar_engine* engine,
                                           shaar_scope scope,
                                           shaar_window* window,
                                           shaar_tab* tab,
                                           shaar_operation operation,
                                           shaar_bytes args,
                                           shaar_request_id request_id,
                                           shaar_reply_fn reply,
                                           void* reply_context,
                                           shaar_error* error) {
  if (scope.size < sizeof(shaar_scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr)))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension scope", error);
  if (!engine || !context || !context->profile_services || !reply ||
      !request_id || !args.data || !args.size)
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension request", error);
  if (scope.private_session)
    return Fail(SHAAR_PRIVATE_DISALLOWED,
                "extension management requires a regular profile", error);

  base::DictValue input;
  if (!ParseArgs(args, &input))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension JSON schema", error);

  // Validate the closed operation schema before resolving any profile service.
  if (operation == SHAAR_OP_EXTENSION_LIST) {
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension list field",
                  error);
  } else if (operation == SHAAR_OP_EXTENSION_MANAGE) {
    const std::string* action = input.FindString("action");
    if (action && *action == "setDeveloperMode") {
      if (!shaar::extensions_host::DeveloperModePayloadValid(input))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid developer mode request",
                    error);
    } else if (action && *action == "loadUnpacked") {
      const std::string* path = input.FindString("path");
      if (!shaar::extensions_host::UnpackedPayloadValid(input) || !path ||
          shaar::extensions_host::InspectUnpackedFolder(
              base::FilePath::FromUTF8Unsafe(*path)) !=
              shaar::extensions_host::UnpackedFolderStatus::kOk)
        return Fail(SHAAR_INVALID_ARGUMENT,
                    "unpacked extension folder is not manifest v3", error);
    } else if (action && *action == "setSiteAccess") {
      if (!shaar::extensions_host::SiteAccessPayloadValid(input))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid site access request",
                    error);
    } else {
      const std::string* id = input.FindString("extensionId");
      if (!action || !id || !ValidExtensionId(*id))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action or ID",
                    error);
      if (*action == "setEnabled" || *action == "setIncognitoEnabled") {
        if (!HasOnlyKeys(
                input, {"schemaVersion", "action", "extensionId", "enabled"}) ||
            !input.FindBool("enabled").has_value())
          return Fail(SHAAR_INVALID_ARGUMENT,
                      "invalid extension enable request", error);
      } else if (*action == "uninstall") {
        if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId"}))
          return Fail(SHAAR_INVALID_ARGUMENT,
                      "invalid extension uninstall request", error);
      } else if (*action == "install") {
        if (!ValidInstallSource(input))
          return Fail(SHAAR_INVALID_ARGUMENT,
                      "invalid extension install source", error);
      } else {
        return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension action", error);
      }
    }
  } else if (operation == SHAAR_OP_EXTENSION_ACTION ||
             operation == SHAAR_OP_EXTENSION_ACTION_STATE) {
    const std::string* id = input.FindString("extensionId");
    if (!HasOnlyKeys(input, {"schemaVersion", "extensionId"}) || !id ||
        !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action request",
                  error);
  } else if (operation == SHAAR_OP_EXTENSION_INSTALL_DECISION) {
    const std::string* consent_id = input.FindString("consentRequestId");
    if (!HasOnlyKeys(input,
                     {"schemaVersion", "consentRequestId", "accepted"}) ||
        !consent_id || consent_id->empty() ||
        !input.FindBool("accepted").has_value())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension consent decision",
                  error);
  } else if (operation == SHAAR_OP_EXTENSION_POPUP_CLOSE) {
    const std::string* popup_id = input.FindString("popupId");
    if (!HasOnlyKeys(input, {"schemaVersion", "popupId"}) || !popup_id ||
        popup_id->empty())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension popup close",
                  error);
  } else if (operation == SHAAR_OP_EXTENSION_WEB_STORE_ZOOM) {
    const auto zoom = Number(input, "zoomFactor");
    const auto applied = Number(input, "appliedZoom");
    if (!HasOnlyKeys(input, {"schemaVersion", "zoomFactor", "appliedZoom"}) ||
        !zoom || !applied || !std::isfinite(*zoom) ||
        !std::isfinite(*applied) || *zoom < 0.67 || *zoom > 1 || *applied < 0 ||
        *applied > 1)
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid Web Store zoom", error);
  } else if (operation == SHAAR_OP_EXTENSION_MANAGER_OPEN) {
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid manager open request",
                  error);
  } else if (operation == SHAAR_OP_PROBE_FRAMEWORK_DEVTOOLS) {
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid component audit schema",
                  error);
  } else {
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY, "unknown extension operation",
                error);
  }

  Profile* profile =
      context->profile_services->ResolveProfile(engine, scope.profile);
  if (!profile || profile->IsOffTheRecord() ||
      profile->GetOriginalProfile() != profile)
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  if (operation == SHAAR_OP_EXTENSION_WEB_STORE_ZOOM) {
    if (!window || !tab || !context->browser_tabs)
      return Fail(SHAAR_INVALID_ARGUMENT, "Web Store zoom needs a tab", error);
    content::WebContents* contents =
        context->browser_tabs->FindWebContents(engine, window, tab);
    if (!contents || contents->GetBrowserContext() != profile)
      return Fail(SHAAR_WRONG_PROFILE, "Web Store tab scope mismatch", error);
    const GURL& committed = contents->GetLastCommittedURL();
    const GURL& visible = contents->GetVisibleURL();
    if (!committed.SchemeIs("https") ||
        committed.host() != "chromewebstore.google.com" ||
        visible.scheme() != committed.scheme() ||
        visible.host() != committed.host())
      return Fail(SHAAR_POLICY_BLOCKED, "Web Store zoom host mismatch", error);
    const double requested = *Number(input, "zoomFactor");
    const double applied = *Number(input, "appliedZoom");
    const double current = blink::ZoomLevelToZoomFactor(
        content::HostZoomMap::GetZoomLevel(contents));
    const bool manual = applied > 0 && std::fabs(current - applied) > 0.005;
    if (!manual && std::fabs(current - requested) > 0.005)
      content::HostZoomMap::SetZoomLevel(
          contents, blink::ZoomFactorToZoomLevel(requested));
    base::DictValue result;
    result.Set("schemaVersion", 1);
    result.Set("manual", manual);
    result.Set("zoomFactor", manual ? current : requested);
    std::string json;
    if (!base::JSONWriter::Write(base::Value(std::move(result)), &json))
      return Fail(SHAAR_CHROMIUM_ERROR, "could not encode Web Store zoom",
                  error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(json));
    return SHAAR_OK;
  }

  auto* registry = extensions::ExtensionRegistry::Get(profile);
  if (!registry)
    return Fail(SHAAR_NOT_READY, "extension registry is unavailable", error);

  if (operation == SHAAR_OP_PROBE_FRAMEWORK_DEVTOOLS) {
    const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
    if (!testing || std::strcmp(testing, "1") != 0)
      return Fail(SHAAR_POLICY_BLOCKED, "component audit requires testing mode",
                  error);
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid component audit schema",
                  error);
    auto* loader = extensions::ComponentLoader::Get(profile);
    base::ListValue entries;
    for (std::string_view name : {"react", "vue", "angular"}) {
      const std::string id(shaar::extensions_host::FrameworkDevToolsID(name));
      base::DictValue row;
      row.Set("name", name);
      row.Set("id", id);
      row.Set("registered", loader && loader->Exists(id));
      row.Set("enabled",
              registry->GetExtensionById(
                  id, extensions::ExtensionRegistry::ENABLED) != nullptr);
      entries.Append(std::move(row));
    }
    base::DictValue result;
    result.Set("schemaVersion", 1);
    result.Set("components", std::move(entries));
    std::string json;
    if (!base::JSONWriter::Write(base::Value(std::move(result)), &json))
      return Fail(SHAAR_CHROMIUM_ERROR, "could not encode component audit",
                  error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(json));
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_EXTENSION_LIST) {
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension list field",
                  error);
    auto payload = EncodeList(profile, registry);
    if (!payload)
      return Fail(SHAAR_CHROMIUM_ERROR, "could not encode extension list",
                  error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
               std::move(*payload));
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_EXTENSION_MANAGER_OPEN) {
    if (!window || !context->browser_tabs)
      return Fail(SHAAR_INVALID_ARGUMENT, "extension manager needs a window",
                  error);
    Browser* browser = context->browser_tabs->FindBrowser(engine, window);
    if (!browser || browser->GetProfile() != profile)
      return Fail(SHAAR_WRONG_PROFILE, "manager window scope mismatch", error);
    if (!shaar::extensions_host::RegisterBundledManager(profile))
      return Fail(SHAAR_NOT_READY, "bundled manager could not load", error);
    constexpr char kManagerID[] = "bphhlegomeaogfihjcipdbcfbgkcfafp";
    const extensions::Extension* manager =
        registry->enabled_extensions().GetByID(kManagerID);
    if (!manager)
      return Fail(SHAAR_NOT_READY, "bundled manager is loading", error);
    const GURL url(std::string("chrome-extension://") + kManagerID +
                   "/manager.html");
    auto popup_id = shaar::extensions_host::OpenPopup(engine, scope.profile,
                                                      window, nullptr, browser,
                                                      profile, *manager, url);
    if (!popup_id)
      return Fail(SHAAR_CHROMIUM_ERROR, "manager page could not open", error);
    base::DictValue result;
    result.Set("schemaVersion", 1);
    result.Set("popupId", *popup_id);
    std::string json;
    if (!base::JSONWriter::Write(base::Value(std::move(result)), &json))
      return Fail(SHAAR_CHROMIUM_ERROR, "manager response could not encode",
                  error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(json));
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_EXTENSION_MANAGE) {
    const std::string* action = input.FindString("action");
    if (action && *action == "setDeveloperMode") {
      const auto enabled = input.FindBool("enabled");
      return shaar::extensions_host::ApplyDeveloperMode(
          profile, enabled.value_or(false), reply, reply_context, request_id,
          error);
    }
    if (action && *action == "loadUnpacked") {
      return shaar::extensions_host::BeginUnpackedLoad(
          context, engine, window, tab, profile, input, reply, reply_context,
          request_id, error);
    }
    if (action && *action == "setSiteAccess") {
      return shaar::extensions_host::ApplySiteAccess(
          context, engine, window, tab, profile, input, reply, reply_context,
          request_id, error);
    }
    const std::string* id = input.FindString("extensionId");
    if (!action || !id || !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action or ID",
                  error);
    if (*action == "setEnabled") {
      if (!HasOnlyKeys(input,
                       {"schemaVersion", "action", "extensionId", "enabled"}))
        return Fail(SHAAR_INVALID_ARGUMENT, "unknown setEnabled field", error);
      const auto enabled = input.FindBool("enabled");
      if (!enabled.has_value())
        return Fail(SHAAR_INVALID_ARGUMENT, "enabled must be Boolean", error);
      auto* registrar = extensions::ExtensionRegistrar::Get(profile);
      auto* extension_system = extensions::ExtensionSystem::Get(profile);
      auto* service =
          extension_system ? extension_system->extension_service() : nullptr;
      const extensions::Extension* extension = registry->GetExtensionById(
          *id, extensions::ExtensionRegistry::EVERYTHING);
      if (!extension)
        return Fail(SHAAR_NOT_FOUND, "extension is not installed", error);
      if (!registrar || !service)
        return Fail(SHAAR_NOT_READY, "extension service is unavailable", error);
      if (*enabled && (registry->GetExtensionById(
                           *id, extensions::ExtensionRegistry::BLOCKED) ||
                       registry->GetExtensionById(
                           *id, extensions::ExtensionRegistry::BLOCKLISTED)))
        return Fail(SHAAR_POLICY_BLOCKED, "extension is blocked", error);
      if (!*enabled && !service->UserCanDisableInstalledExtension(*id))
        return Fail(SHAAR_POLICY_BLOCKED, "extension is managed", error);
      const bool already_enabled =
          registry->GetExtensionById(extension->id(),
                                     extensions::ExtensionRegistry::ENABLED) !=
          nullptr;
      if (*enabled && !already_enabled)
        registrar->EnableExtension(*id);
      else if (!*enabled && already_enabled)
        registrar->DisableExtension(
            *id, {extensions::disable_reason::DISABLE_USER_ACTION});
      const bool now_enabled =
          registry->GetExtensionById(extension->id(),
                                     extensions::ExtensionRegistry::ENABLED) !=
          nullptr;
      if (now_enabled != *enabled)
        return Fail(SHAAR_POLICY_BLOCKED, "extension state did not change",
                    error);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                 "{\"schemaVersion\":1,\"updated\":true}");
      return SHAAR_OK;
    }
    if (*action == "uninstall") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId"}))
        return Fail(SHAAR_INVALID_ARGUMENT, "unknown uninstall field", error);
      auto* registrar = extensions::ExtensionRegistrar::Get(profile);
      if (!registrar)
        return Fail(SHAAR_NOT_READY, "extension registrar is unavailable",
                    error);
      if (!registry->GetExtensionById(
              *id, extensions::ExtensionRegistry::EVERYTHING))
        return Fail(SHAAR_NOT_FOUND, "extension is not installed", error);
      std::u16string diagnostic;
      if (!registrar->UninstallExtension(
              *id, extensions::UNINSTALL_REASON_USER_INITIATED, &diagnostic))
        return Fail(SHAAR_POLICY_BLOCKED, "extension cannot be removed", error);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                 "{\"schemaVersion\":1,\"removed\":true}");
      return SHAAR_OK;
    }
    if (*action == "setIncognitoEnabled") {
      if (!HasOnlyKeys(input,
                       {"schemaVersion", "action", "extensionId", "enabled"}) ||
          !input.FindBool("enabled").has_value())
        return Fail(SHAAR_INVALID_ARGUMENT,
                    "invalid incognito visibility request", error);
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "incognito visibility policy integration is not available",
                  error);
    }
    if (*action == "install") {
      const std::string* source = input.FindString("source");
      if (!ValidInstallSource(input))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension install source",
                    error);
      const extensions::Extension* existing = registry->GetExtensionById(
          *id, extensions::ExtensionRegistry::EVERYTHING);
      if (*source == "sharedHome" && existing &&
          (!existing->is_extension() || !existing->from_webstore()))
        return Fail(SHAAR_CONFLICT, "extension is not a Web Store install",
                    error);
      if (*source == "sharedHome" && existing) {
        if (!SharedHomeVersionSatisfied(existing->version().GetString(),
                                        *input.FindString("approvedVersion"))) {
          auto* system = extensions::ExtensionSystem::Get(profile);
          auto* service = system ? system->extension_service() : nullptr;
          if (!service)
            return Fail(SHAAR_NOT_READY, "extension updater is unavailable",
                        error);
          service->CheckForUpdatesSoon();
          ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                     "{\"schemaVersion\":1,\"queued\":true}");
          return SHAAR_OK;
        }
        ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                   "{\"schemaVersion\":1,\"installed\":true}");
        return SHAAR_OK;
      }
      if (*source == "sharedHome") {
        auto* extension_system = extensions::ExtensionSystem::Get(profile);
        auto* service =
            extension_system ? extension_system->extension_service() : nullptr;
        auto* pending = extensions::PendingExtensionManager::Get(profile);
        if (!service || !pending)
          return Fail(SHAAR_NOT_READY, "extension installer is unavailable",
                      error);
        if (!pending->IsIdPending(*id)) {
          const std::string& version = *input.FindString("approvedVersion");
          if (!pending->AddFromSync(*id, extension_urls::GetWebstoreUpdateUrl(),
                                    base::Version(version), &IsRegularExtension,
                                    false))
            return Fail(SHAAR_POLICY_BLOCKED, "extension install was blocked",
                        error);
          service->CheckForUpdatesSoon();
        }
        ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                   "{\"schemaVersion\":1,\"queued\":true}");
        return SHAAR_OK;
      }
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "extension operation requires consent/policy integration",
                  error);
    }
    return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension action", error);
  }

  if (operation == SHAAR_OP_EXTENSION_ACTION ||
      operation == SHAAR_OP_EXTENSION_ACTION_STATE) {
    const std::string* id = input.FindString("extensionId");
    if (!HasOnlyKeys(input, {"schemaVersion", "extensionId"}) || !id ||
        !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action request",
                  error);
    if (!window || !tab || !context->browser_tabs)
      return Fail(SHAAR_INVALID_ARGUMENT, "extension action needs a tab",
                  error);
    content::WebContents* contents =
        context->browser_tabs->FindWebContents(engine, window, tab);
    Browser* browser = context->browser_tabs->FindBrowser(engine, window);
    if (!contents || contents->GetBrowserContext() != profile || !browser ||
        browser->tab_strip_model()->GetActiveWebContents() != contents)
      return Fail(SHAAR_WRONG_PROFILE, "extension action tab scope mismatch",
                  error);
    const extensions::Extension* extension =
        registry->GetExtensionById(*id, extensions::ExtensionRegistry::ENABLED);
    if (!extension)
      return Fail(SHAAR_NOT_FOUND, "enabled extension not found", error);
    auto* manager = extensions::ExtensionActionManager::Get(profile);
    auto* action = manager ? manager->GetExtensionAction(*extension) : nullptr;
    if (!action)
      return Fail(SHAAR_NOT_FOUND, "extension has no action", error);
    int tab_id = extensions::ExtensionTabUtil::GetTabId(contents);
    if (operation == SHAAR_OP_EXTENSION_ACTION_STATE) {
      base::DictValue state;
      state.Set("schemaVersion", 1);
      state.Set("title", action->GetTitle(tab_id));
      state.Set("hasPopup", action->HasPopup(tab_id));
      std::string json;
      if (!base::JSONWriter::Write(base::Value(std::move(state)), &json))
        return Fail(SHAAR_CHROMIUM_ERROR, "could not encode action state",
                    error);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(json));
      return SHAAR_OK;
    }
    auto* runner =
        extensions::ExtensionActionRunner::GetForWebContents(contents);
    if (!runner)
      return Fail(SHAAR_NOT_READY, "extension action runner unavailable",
                  error);
    if (action->HasPopup(tab_id)) {
      const GURL url = action->GetPopupUrl(tab_id);
      if (!shaar::extensions_host::ValidPopupOrigin(*id, url))
        return Fail(SHAAR_POLICY_BLOCKED, "extension popup origin mismatch",
                    error);
      auto popup_id =
          shaar::extensions_host::OpenPopup(engine, scope.profile, window, tab,
                                            browser, profile, *extension, url);
      if (!popup_id)
        return Fail(SHAAR_CHROMIUM_ERROR, "extension popup could not open",
                    error);
      runner->RunAction(extension, true);
      base::DictValue result;
      result.Set("schemaVersion", 1);
      result.Set("route", "popup");
      result.Set("popupId", *popup_id);
      std::string json;
      if (!base::JSONWriter::Write(base::Value(std::move(result)), &json))
        return Fail(SHAAR_CHROMIUM_ERROR, "popup response could not encode",
                    error);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(json));
      return SHAAR_OK;
    }
    runner->RunAction(extension, true);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
               "{\"schemaVersion\":1,\"route\":\"none\"}");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_EXTENSION_INSTALL_DECISION) {
    const std::string* consent_id = input.FindString("consentRequestId");
    if (!HasOnlyKeys(input,
                     {"schemaVersion", "consentRequestId", "accepted"}) ||
        !consent_id || consent_id->empty() ||
        !input.FindBool("accepted").has_value())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension consent decision",
                  error);
    return shaar::extensions_host::ResolveInstallDecision(
        context, engine, window, tab, profile,
        context->profile_services->ProfileID(engine, scope.profile),
        *consent_id, *input.FindBool("accepted"), reply, reply_context,
        request_id, error);
  }
  if (operation == SHAAR_OP_EXTENSION_POPUP_CLOSE) {
    const std::string* popup_id = input.FindString("popupId");
    if (!HasOnlyKeys(input, {"schemaVersion", "popupId"}) || !popup_id ||
        popup_id->empty())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension popup close",
                  error);
    if (!shaar::extensions_host::ClosePopup(engine, scope.profile, *popup_id))
      return Fail(SHAAR_NOT_FOUND, "extension popup was not found", error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
               "{\"schemaVersion\":1,\"closed\":true}");
    return SHAAR_OK;
  }
  return Fail(SHAAR_UNSUPPORTED_CAPABILITY, "unknown extension operation",
              error);
}
