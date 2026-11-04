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
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"

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
  auto parsed = base::JSONReader::Read(std::string_view(args.data, args.size), base::JSON_PARSE_RFC);
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
  base::ListValue entries;
  const auto installed = registry->GenerateInstalledExtensionsSet();
  for (const auto& extension : installed) {
    base::DictValue row;
    row.Set("id", extension->id());
    row.Set("name", extension->name());
    row.Set("version", extension->version().GetString());
    row.Set("enabled", registry->GetExtensionById(
                            extension->id(), extensions::ExtensionRegistry::ENABLED) !=
                            nullptr);
    row.Set("mayDisable", service &&
                               service->UserCanDisableInstalledExtension(extension->id()));
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

shaar_error_code HandleExtensionsOperation(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window*,
    shaar_tab*,
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
          !source || (*source != "webStore" && *source != "unpacked" &&
                      *source != "sharedHome"))
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
      std::u16string diagnostic;
      if (!registrar->UninstallExtension(
              *id, extensions::UNINSTALL_REASON_USER_INITIATED, &diagnostic))
        return Fail(SHAAR_POLICY_BLOCKED, "extension cannot be removed", error);
      ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                 "{\"schemaVersion\":1,\"removed\":true}");
      return SHAAR_OK;
    }
    if (*action == "setIncognitoEnabled") {
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "enabled"}) ||
          !input.FindBool("enabled").has_value())
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid incognito visibility request", error);
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "incognito visibility policy integration is not available", error);
    }
    // A replay against an already-installed profile is idempotent and must not
    // change that profile's enabled state. Creating a missing instance still
    // requires a reviewed shared package and consent/policy integration.
    if (*action == "install") {
      const std::string* source = input.FindString("source");
      if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "source"}) ||
          !source || (*source != "webStore" && *source != "unpacked" &&
                      *source != "sharedHome"))
        return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension install source", error);
      const extensions::Extension* existing = registry->GetExtensionById(
          *id, extensions::ExtensionRegistry::EVERYTHING);
      if (*source == "sharedHome" && existing &&
          (!existing->is_extension() || !existing->from_webstore()))
        return Fail(SHAAR_CONFLICT, "extension is not a Web Store install", error);
      if (*source == "sharedHome" && existing) {
        ReplyLater({reply, reply_context, request_id}, SHAAR_OK,
                   "{\"schemaVersion\":1,\"installed\":true}");
        return SHAAR_OK;
      }
      return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                  "shared extension package installation is not available", error);
    }
    return Fail(SHAAR_INVALID_ARGUMENT, "unknown extension action", error);
  }

  if (operation == SHAAR_OP_EXTENSION_ACTION) {
    const std::string* id = input.FindString("extensionId");
    if (!HasOnlyKeys(input, {"schemaVersion", "extensionId"}) || !id ||
        !ValidExtensionId(*id))
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension action request", error);
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                "extension action host integration is not available", error);
  }
  if (operation == SHAAR_OP_EXTENSION_INSTALL_DECISION) {
    const std::string* consent_id = input.FindString("consentRequestId");
    if (!HasOnlyKeys(input, {"schemaVersion", "consentRequestId", "accepted"}) ||
        !consent_id || consent_id->empty() || !input.FindBool("accepted").has_value())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension consent decision", error);
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                "extension consent host integration is not available", error);
  }
  if (operation == SHAAR_OP_EXTENSION_POPUP_CLOSE) {
    const std::string* popup_id = input.FindString("popupId");
    if (!HasOnlyKeys(input, {"schemaVersion", "popupId"}) || !popup_id ||
        popup_id->empty())
      return Fail(SHAAR_INVALID_ARGUMENT, "invalid extension popup close", error);
    return Fail(SHAAR_UNSUPPORTED_CAPABILITY,
                "extension popup host integration is not available", error);
  }
  return Fail(SHAAR_UNSUPPORTED_CAPABILITY, "unknown extension operation", error);
}
