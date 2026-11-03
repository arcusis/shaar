// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

#include <stddef.h>
#include <string.h>

#include <algorithm>
#include <initializer_list>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/task/single_thread_task_runner.h"
#include "base/values.h"
#include "chrome/browser/extensions/extension_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"
#include "extensions/common/permissions/permissions_data.h"
#include "extensions/common/url_pattern_set.h"

namespace {

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

bool HasOnlyKeys(const base::Value::Dict& dict,
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

bool ParseArgs(shaar_bytes args, base::Value::Dict* dict) {
  if (!args.data || !args.size || !dict)
    return false;
  auto parsed = base::JSONReader::Read(std::string_view(args.data, args.size));
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

std::optional<std::string> EncodeList(Profile* profile,
                                      extensions::ExtensionRegistry* registry) {
  auto* extension_system = extensions::ExtensionSystem::Get(profile);
  auto* service = extension_system ? extension_system->extension_service() : nullptr;
  base::Value::List entries;
  const auto installed = registry->GenerateInstalledExtensionsSet();
  for (const auto& extension : installed) {
    base::Value::Dict row;
    row.Set("id", extension->id());
    row.Set("name", extension->name());
    row.Set("version", extension->version().GetString());
    row.Set("description", extension->description());
    row.Set("enabled", registry->GetExtensionById(
                            extension->id(), extensions::ExtensionRegistry::ENABLED) !=
                            nullptr);
    row.Set("mayDisable", service &&
                               service->UserCanDisableInstalledExtension(extension->id()));
    row.Set("incognitoEnabled",
            extensions::util::IsIncognitoEnabled(extension.get(), profile));
    base::Value::List permissions;
    for (const auto& permission :
         extension->permissions_data()->active_permissions().apis()) {
      permissions.Append(permission->name());
    }
    row.Set("permissions", std::move(permissions));
    base::Value::List host_permissions;
    for (const auto& pattern : extension->permissions_data()
                                   ->active_permissions()
                                   .effective_hosts()) {
      host_permissions.Append(pattern.GetAsString());
    }
    row.Set("hostPermissions", std::move(host_permissions));
    row.Set("source", static_cast<int>(extension->location()));
    const auto* policy = extension_system ? extension_system->management_policy()
                                          : nullptr;
    row.Set("managementState",
            !policy ? "unknown"
                    : policy->UserMayModifySettings(extension.get(), nullptr)
                          ? "user"
                          : "managed");
    entries.Append(std::move(row));
  }
  base::Value::Dict result;
  result.Set("schemaVersion", 1);
  result.Set("extensions", std::move(entries));
  std::string json;
  if (!base::JSONWriter::Write(base::Value(std::move(result)), &json))
    return std::nullopt;
  return json;
}

void EmitManagementEvent(shaar::ShaarEngineContext* context,
                         shaar_engine* engine,
                         shaar_profile* handle,
                         const char* kind,
                         const std::string& extension_id,
                         std::optional<bool> enabled = std::nullopt) {
  if (!context || !context->profile_services)
    return;
  const std::string profile_id(
      context->profile_services->ProfileID(engine, handle));
  if (profile_id.empty())
    return;
  base::Value::Dict event;
  event.Set("kind", kind);
  event.Set("schemaVersion", 1);
  event.Set("extensionId", extension_id);
  if (enabled.has_value())
    event.Set("enabled", *enabled);
  std::string payload;
  if (!base::JSONWriter::Write(base::Value(std::move(event)), &payload))
    return;
  shaar::EmitEvent(engine, SHAAR_EVENT_EXTENSION,
                   {profile_id.data(), profile_id.size()}, {}, {}, {},
                   {payload.data(), payload.size()});
}

}  // namespace

shaar_error_code HandleExtensionsOperation(
    shaar::ShaarEngineContext* context,
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
  // This migration slice deliberately exposes install/action/consent/popup
  // dispatch only through an injected host. Until the Chromium-backed host is
  // installed at engine startup, these operations fail closed below rather
  // than claiming step-10 parity.
  if (scope.size < sizeof(shaar_scope) ||
      ((scope.profile != nullptr) == (scope.private_session != nullptr)))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension scope", error);
  if (!engine || !context || !context->profile_services || !reply ||
      !request_id || !args.data || !args.size)
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension request", error);
  if (scope.private_session)
    return Fail(SHAAR_PRIVATE_DISALLOWED,
                "extension management requires a regular profile", error);

  base::Value::Dict input;
  if (!ParseArgs(args, &input))
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension JSON schema", error);

  // Validate the closed operation schema before resolving any profile service.
  if (operation == SHAAR_OP_EXTENSION_LIST) {
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension list field", error);
  } else if (operation == SHAAR_OP_EXTENSION_MANAGE) {
    const std::string* action = input.FindString("action");
    const std::string* id = input.FindString("extensionId");
    if (!action || !id || !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action or ID", error);
    if (*action == "setEnabled" || *action == "setIncognitoEnabled") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "enabled"}) ||
          !input.FindBool("enabled").has_value())
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension enable request", error);
    } else if (*action == "uninstall") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId"}))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension uninstall request", error);
    } else if (*action == "install") {
      const std::string* source = input.FindString("source");
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "source"}) ||
          !source || (*source != "webStore" && *source != "unpacked"))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension install source", error);
    } else {
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension action", error);
    }
  } else if (operation == SHAAR_OP_EXTENSION_ACTION) {
    const std::string* id = input.FindString("extensionId");
    if (!HasOnlyKeys(input, {"schemaVersion", "extensionId"}) || !id ||
        !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action request", error);
  } else if (operation == SHAAR_OP_EXTENSION_INSTALL_DECISION) {
    const std::string* consent_id = input.FindString("consentRequestId");
    if (!HasOnlyKeys(input, {"schemaVersion", "consentRequestId", "accepted"}) ||
        !consent_id || consent_id->empty() || !input.FindBool("accepted").has_value())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension consent decision", error);
  } else if (operation == SHAAR_OP_EXTENSION_POPUP_CLOSE) {
    const std::string* popup_id = input.FindString("popupId");
    if (!HasOnlyKeys(input, {"schemaVersion", "popupId"}) || !popup_id ||
        popup_id->empty())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension popup close", error);
  } else {
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY, "unknown extension operation", error);
  }

  // These host-facing operations validate opaque ownership in the injected
  // runtime service. They do not resolve or retain Chromium pointers here.
  if (operation == SHAAR_OP_EXTENSION_MANAGE &&
      input.FindString("action") && *input.FindString("action") == "install") {
    const std::string* id = input.FindString("extensionId");
    const std::string* source = input.FindString("source");
    if (!window || !tab)
      return Fail(SHAAR_INVALID_ARGUMENT, "install requires an owning tab", error);
    if (!context->extensions)
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "extension install host is unavailable", error);
    const shaar_error_code result = context->extensions->BeginInstall(
        engine, scope.profile, window, tab, *id, *source);
    if (result != SHAAR_OK)
      return Fail(result, "extension install request was rejected", error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
               "{\"schemaVersion\":1,\"accepted\":true}");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_EXTENSION_ACTION) {
    const std::string* id = input.FindString("extensionId");
    if (!window || !tab)
      return Fail(SHAAR_INVALID_ARGUMENT, "extension action requires a tab", error);
    if (!context->extensions)
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "extension action host is unavailable", error);
    std::string route;
    const shaar_error_code result = context->extensions->InvokeAction(
        engine, scope.profile, window, tab, *id, &route);
    if (result != SHAAR_OK)
      return Fail(result, "extension action was rejected", error);
    if (route != "none" && route != "popup" && route != "sidePanel")
      return Fail(SHAAR_CHROMIUM_ERROR, "extension host returned an invalid route", error);
    base::Value::Dict payload;
    payload.Set("schemaVersion", 1);
    payload.Set("route", route);
    std::string json;
    if (!base::JSONWriter::Write(base::Value(std::move(payload)), &json))
      return Fail(SHAAR_CHROMIUM_ERROR, "could not encode action result", error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(json));
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_EXTENSION_INSTALL_DECISION) {
    const std::string* consent_id = input.FindString("consentRequestId");
    if (!context->extensions)
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "extension consent host is unavailable", error);
    const shaar_error_code result = context->extensions->ResolveInstallDecision(
        engine, scope.profile, *consent_id, *input.FindBool("accepted"));
    if (result != SHAAR_OK)
      return Fail(result, "extension consent decision was rejected", error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
               "{\"schemaVersion\":1,\"resolved\":true}");
    return SHAAR_OK;
  }
  if (operation == SHAAR_OP_EXTENSION_POPUP_CLOSE) {
    const std::string* popup_id = input.FindString("popupId");
    if (!window)
      return Fail(SHAAR_INVALID_ARGUMENT, "popup close requires a window", error);
    if (!context->extensions)
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "extension popup host is unavailable", error);
    const shaar_error_code result = context->extensions->ClosePopup(
        engine, scope.profile, window, *popup_id);
    if (result != SHAAR_OK)
      return Fail(result, "extension popup close was rejected", error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
               "{\"schemaVersion\":1,\"closed\":true}");
    return SHAAR_OK;
  }

  Profile* profile = context->profile_services->ResolveProfile(engine, scope.profile);
  if (!profile || profile->IsOffTheRecord() ||
      profile->GetOriginalProfile() != profile)
    return Fail(SHAAR_NOT_FOUND, "profile handle is stale", error);
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  if (!registry)
    return Fail(SHAAR_NOT_READY, "extension registry is unavailable", error);

  if (operation == SHAAR_OP_EXTENSION_LIST) {
    if (!HasOnlyKeys(input, {"schemaVersion"}))
      return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension list field", error);
    auto payload = EncodeList(profile, registry);
    if (!payload)
      return Fail(SHAAR_CHROMIUM_ERROR, "could not encode extension list", error);
    ReplyLater({reply, reply_context, request_id}, SHAAR_OK, std::move(*payload));
    return SHAAR_OK;
  }

  if (operation == SHAAR_OP_EXTENSION_MANAGE) {
    const std::string* action = input.FindString("action");
    const std::string* id = input.FindString("extensionId");
    if (!action || !id || !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action or ID", error);
    if (*action == "setEnabled") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "enabled"}))
        return Fail(SHAAR_INVALID_ARGUMENT, "unknown setEnabled field", error);
      const auto enabled = input.FindBool("enabled");
      if (!enabled.has_value())
        return Fail(SHAAR_INVALID_ARGUMENT, "enabled must be Boolean", error);
      auto* registrar = extensions::ExtensionRegistrar::Get(profile);
      auto* extension_system = extensions::ExtensionSystem::Get(profile);
      auto* service = extension_system ? extension_system->extension_service() : nullptr;
      const extensions::Extension* extension =
          registry->GetExtensionById(*id, extensions::ExtensionRegistry::EVERYTHING);
      if (!extension)
        return Fail(SHAAR_NOT_FOUND, "extension is not installed", error);
      if (!registrar || !service)
        return Fail(SHAAR_NOT_READY, "extension service is unavailable", error);
      if (*enabled &&
          (registry->GetExtensionById(*id, extensions::ExtensionRegistry::BLOCKED) ||
           registry->GetExtensionById(*id,
                                      extensions::ExtensionRegistry::BLOCKLISTED)))
        return Fail(SHAAR_POLICY_BLOCKED, "extension is blocked", error);
      if (!*enabled && !service->UserCanDisableInstalledExtension(*id))
        return Fail(SHAAR_POLICY_BLOCKED, "extension is managed", error);
      const bool already_enabled = registry->GetExtensionById(
                                       extension->id(),
                                       extensions::ExtensionRegistry::ENABLED) != nullptr;
      if (*enabled && !already_enabled)
        registrar->EnableExtension(*id);
      else if (!*enabled && already_enabled)
        registrar->DisableExtension(
            *id, {extensions::disable_reason::DISABLE_USER_ACTION});
      const bool now_enabled = registry->GetExtensionById(
                                   extension->id(),
                                   extensions::ExtensionRegistry::ENABLED) != nullptr;
      if (now_enabled != *enabled)
        return Fail(SHAAR_POLICY_BLOCKED, "extension state did not change", error);
      EmitManagementEvent(context, engine, scope.profile,
                          "extension.enabledChanged", *id, *enabled);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                 "{\"schemaVersion\":1,\"updated\":true}");
      return SHAAR_OK;
    }
    if (*action == "uninstall") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId"}))
        return Fail(SHAAR_INVALID_ARGUMENT, "unknown uninstall field", error);
      auto* registrar = extensions::ExtensionRegistrar::Get(profile);
      if (!registrar)
        return Fail(SHAAR_NOT_READY, "extension registrar is unavailable", error);
      if (!registry->GetExtensionById(*id,
                                      extensions::ExtensionRegistry::EVERYTHING))
        return Fail(SHAAR_NOT_FOUND, "extension is not installed", error);
      auto* extension_system = extensions::ExtensionSystem::Get(profile);
      const auto* installed = registry->GetExtensionById(
          *id, extensions::ExtensionRegistry::EVERYTHING);
      if (extension_system && extension_system->management_policy() &&
          !extension_system->management_policy()->UserMayModifySettings(
              installed, nullptr))
        return Fail(SHAAR_POLICY_BLOCKED, "extension is managed", error);
      auto* extension_service = extension_system
                                    ? extension_system->extension_service()
                                    : nullptr;
      if (!extension_service ||
          !extension_service->UserCanDisableInstalledExtension(*id))
        return Fail(SHAAR_POLICY_BLOCKED, "extension cannot be removed", error);
      std::u16string diagnostic;
      if (!registrar->UninstallExtension(
              *id, extensions::UNINSTALL_REASON_USER_INITIATED, &diagnostic))
        return Fail(SHAAR_POLICY_BLOCKED, "extension cannot be removed", error);
      EmitManagementEvent(context, engine, scope.profile,
                          "extension.removed", *id);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                 "{\"schemaVersion\":1,\"removed\":true}");
      return SHAAR_OK;
    }
    if (*action == "setIncognitoEnabled") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "enabled"}) ||
          !input.FindBool("enabled").has_value())
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid incognito visibility request", error);
      const bool enabled = *input.FindBool("enabled");
      const auto* extension = registry->GetExtensionById(
          *id, extensions::ExtensionRegistry::EVERYTHING);
      auto* extension_system = extensions::ExtensionSystem::Get(profile);
      auto* extension_service = extension_system
                                    ? extension_system->extension_service()
                                    : nullptr;
      if (!extension)
        return Fail(SHAAR_NOT_FOUND, "extension is not installed", error);
      if (!extension_service || !extension_system ||
          !extension_system->management_policy())
        return Fail(SHAAR_NOT_READY, "extension policy is unavailable", error);
      if (!extensions::util::CanBeIncognitoEnabled(extension))
        return Fail(SHAAR_POLICY_BLOCKED,
                    "extension cannot run in private sessions", error);
      if (!extension_system->management_policy()->UserMayModifySettings(
              extension, nullptr))
        return Fail(SHAAR_POLICY_BLOCKED, "extension settings are managed",
                    error);
      extensions::util::SetIsIncognitoEnabled(*id, profile, enabled);
      EmitManagementEvent(context, engine, scope.profile,
                          "extension.incognitoVisibilityChanged", *id,
                          enabled);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                 "{\"schemaVersion\":1,\"updated\":true}");
      return SHAAR_OK;
    }
    return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension action", error);
  }
  return Fail(SHAAR_UNSUPPORTED_CAPABILITY, "unknown extension operation", error);
}
