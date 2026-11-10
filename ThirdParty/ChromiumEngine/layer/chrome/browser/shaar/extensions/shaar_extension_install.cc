// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extension_install.h"

#include <stddef.h>
#include <string.h>

#include <map>
#include <memory>
#include <string>
#include <utility>

#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/pref_names.h"
#include "components/crx_file/id_util.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/browser/permissions/site_permissions_helper.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/common/extension.h"
#include "extensions/common/permissions/permissions_data.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace shaar::extensions_host {
namespace {

constexpr size_t kMaxPendingInstalls = 8;
constexpr size_t kMaxManifestBytes = 1024 * 1024;
constexpr size_t kMaxListedPermissions = 128;
constexpr size_t kMaxPermissionBytes = 8192;

struct PendingInstall {
  enum class Kind { kDialog, kUnpacked };
  Kind kind = Kind::kDialog;
  shaar_engine* engine = nullptr;
  shaar_window* window = nullptr;
  shaar_tab* tab = nullptr;
  std::string profile_id;
  std::string window_id;
  std::string tab_id;
  GURL page_url;
  base::FilePath unpacked_path;
  bool withhold_on_accept = false;
  ExtensionInstallPrompt::DoneCallback done;
};

using PendingMap = std::map<std::string, PendingInstall>;

PendingMap& Pending() {
  static base::NoDestructor<PendingMap> pending;
  return *pending;
}

uint64_t& NextRequestID() {
  static base::NoDestructor<uint64_t> next(0);
  return *next;
}

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

void Reply(shaar_reply_fn reply,
           void* reply_context,
           shaar_request_id request_id,
           shaar_error_code code,
           std::string payload) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](shaar_reply_fn reply, void* reply_context,
             shaar_request_id request_id, shaar_error_code code,
             std::string payload) {
            if (!reply)
              return;
            shaar_result result = {};
            result.size = sizeof(result);
            result.request_id = request_id;
            result.error.size = sizeof(result.error);
            result.error.code = code;
            result.payload_json = {payload.data(), payload.size()};
            reply(reply_context, &result);
          },
          reply, reply_context, request_id, code, std::move(payload)));
}

void ReplyUpdated(shaar_reply_fn reply,
                  void* reply_context,
                  shaar_request_id request_id) {
  Reply(reply, reply_context, request_id, SHAAR_OK,
        "{\"schemaVersion\":1,\"updated\":true}");
}

void ReplyRefused(shaar_reply_fn reply,
                  void* reply_context,
                  shaar_request_id request_id,
                  shaar_error_code code) {
  Reply(reply, reply_context, request_id, code, "{\"schemaVersion\":1}");
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

bool ExtensionIdIsAcceptable(std::string_view id) {
  if (id.size() != 32)
    return false;
  for (char character : id) {
    if (character < 'a' || character > 'p')
      return false;
  }
  return true;
}

bool HasVisibleCharacter(std::string_view text) {
  for (unsigned char character : text) {
    if (character != ' ' && character != '\t' && character != '\n' &&
        character != '\r')
      return true;
  }
  return false;
}

bool TextFits(std::string_view text, size_t max_bytes) {
  return HasVisibleCharacter(text) && text.size() <= max_bytes;
}

bool PageCanHostInstall(const GURL& page) {
  return page.is_valid() && page.SchemeIsHTTPOrHTTPS() && page.has_host();
}

bool OriginPayload(std::string_view text) {
  const GURL url(text);
  if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || !url.has_host())
    return false;
  if (url.has_username() || url.has_password() || url.has_query() ||
      url.has_ref())
    return false;
  return url.path() == "/";
}

void Decline(ExtensionInstallPrompt::DoneCallback done) {
  if (done.is_null())
    return;
  using Result = extensions::ExtensionInstallPromptClient::Result;
  std::move(done).Run(
      extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          Result::USER_CANCELED));
}

void AcceptDialog(PendingInstall pending) {
  if (pending.done.is_null())
    return;
  using Result = extensions::ExtensionInstallPromptClient::Result;
  Result result = Result::ACCEPTED;
  if (pending.withhold_on_accept)
    result = Result::ACCEPTED_WITH_WITHHELD_PERMISSIONS;
  std::move(pending.done)
      .Run(extensions::ExtensionInstallPromptClient::DoneCallbackPayload(
          result));
}

void DropPending(std::string request_id) {
  auto found = Pending().find(request_id);
  if (found == Pending().end())
    return;
  PendingInstall pending = std::move(found->second);
  Pending().erase(found);
  Decline(std::move(pending.done));
}

base::ListValue StringList(const base::DictValue& manifest, const char* key) {
  base::ListValue values;
  const base::ListValue* list = manifest.FindList(key);
  if (!list)
    return values;
  for (const base::Value& item : *list) {
    if (values.size() >= kMaxListedPermissions)
      break;
    const std::string* text = item.GetIfString();
    if (!text || text->empty() || text->size() > kMaxPermissionBytes)
      continue;
    values.Append(*text);
  }
  return values;
}

std::optional<base::DictValue> ReadManifest(const base::FilePath& manifest) {
  std::string contents;
  if (!base::ReadFileToStringWithMaxSize(manifest, &contents,
                                         kMaxManifestBytes))
    return std::nullopt;
  auto parsed = base::JSONReader::Read(contents, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return std::nullopt;
  return std::move(parsed->GetDict());
}

bool ManifestIsVersion3(const base::DictValue& manifest) {
  const std::optional<int> version = manifest.FindInt("manifest_version");
  const std::string* name = manifest.FindString("name");
  const std::string* extension_version = manifest.FindString("version");
  return version.has_value() && *version == 3 && name &&
         TextFits(*name, 1024) && extension_version &&
         TextFits(*extension_version, 128);
}

content::WebContents* ContentsForRequest(ShaarEngineContext* context,
                                         shaar_engine* engine,
                                         shaar_window* window,
                                         shaar_tab* tab) {
  if (!context || !context->browser_tabs || !engine || !window)
    return nullptr;
  if (tab)
    return context->browser_tabs->FindWebContents(engine, window, tab);
  Browser* browser = context->browser_tabs->FindBrowser(engine, window);
  if (!browser || !browser->tab_strip_model())
    return nullptr;
  return browser->tab_strip_model()->GetActiveWebContents();
}

std::optional<windows_tabs::SelectedRegularTab> BindSelectedPage(
    ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_window* window,
    shaar_tab* tab,
    content::WebContents** contents_out) {
  content::WebContents* contents =
      ContentsForRequest(context, engine, window, tab);
  if (!contents || !lifecycle::EngineIsReady(engine))
    return std::nullopt;
  const GURL& page = contents->GetLastCommittedURL();
  if (!PageCanHostInstall(page))
    return std::nullopt;
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(engine, contents);
  if (!identity || identity->profile_id.empty() ||
      identity->window_id.empty() || identity->tab_id.empty())
    return std::nullopt;
  if (tab && identity->tab != tab)
    return std::nullopt;
  if (contents_out)
    *contents_out = contents;
  return identity;
}

bool RequestStillCurrent(ShaarEngineContext* context,
                         const PendingInstall& pending) {
  if (!lifecycle::EngineIsReady(pending.engine))
    return false;
  content::WebContents* contents =
      ContentsForRequest(context, pending.engine, pending.window, pending.tab);
  if (!contents)
    return false;
  auto identity =
      windows_tabs::Registry().FindSelectedRegularTab(pending.engine, contents);
  if (!identity)
    return false;
  return identity->window == pending.window && identity->tab == pending.tab &&
         identity->profile_id == pending.profile_id &&
         identity->window_id == pending.window_id &&
         identity->tab_id == pending.tab_id &&
         contents->GetLastCommittedURL() == pending.page_url;
}

bool EmitForEngine(shaar_engine* engine,
                   const windows_tabs::SelectedRegularTab& identity,
                   const std::string& json) {
  if (engine != lifecycle::ActiveEngine())
    return false;
  return shaar::EmitEvent(
             engine, SHAAR_EVENT_EXTENSION,
             {identity.profile_id.data(), identity.profile_id.size()}, {},
             {identity.window_id.data(), identity.window_id.size()},
             {identity.tab_id.data(), identity.tab_id.size()},
             {json.data(), json.size()}) == SHAAR_OK;
}

void AddPermissionList(base::DictValue* payload,
                       const char* key,
                       base::ListValue values) {
  if (!values.empty())
    payload->Set(key, std::move(values));
}

std::optional<extensions::PermissionsManager::UserSiteAccess> SiteAccessValue(
    std::string_view access) {
  using Access = extensions::PermissionsManager::UserSiteAccess;
  if (access == "onClick")
    return Access::kOnClick;
  if (access == "onSite")
    return Access::kOnSite;
  if (access == "onAllSites")
    return Access::kOnAllSites;
  return std::nullopt;
}

bool DeveloperModeEnabled(Profile* profile) {
  PrefService* prefs = profile ? profile->GetPrefs() : nullptr;
  if (!prefs || !prefs->FindPreference(prefs::kExtensionsUIDeveloperMode))
    return false;
  return prefs->GetBoolean(prefs::kExtensionsUIDeveloperMode);
}

void StartUnpackedLoad(Profile* profile, const base::FilePath& path) {
  scoped_refptr<extensions::UnpackedInstaller> installer =
      extensions::UnpackedInstaller::Create(profile);
  if (!installer)
    return;
  installer->set_be_noisy_on_failure(false);
  installer->set_completion_callback(
      base::BindOnce([](scoped_refptr<extensions::UnpackedInstaller>,
                        const extensions::Extension*, const base::FilePath&,
                        const std::u16string&) {},
                     installer));
  installer->Load(path);
}

}  // namespace

UnpackedFolderStatus InspectUnpackedFolder(const base::FilePath& path,
                                           base::FilePath* resolved) {
  // Reject parent references on the caller's path before resolving links.
  if (!path.IsAbsolute() || path.ReferencesParent() || path.empty())
    return UnpackedFolderStatus::kInvalid;
  const base::FilePath folder = base::MakeAbsoluteFilePath(path);
  if (folder.empty() || base::IsLink(folder) || !base::DirectoryExists(folder))
    return UnpackedFolderStatus::kInvalid;
  const base::FilePath manifest =
      base::MakeAbsoluteFilePath(folder.AppendASCII("manifest.json"));
  if (manifest.empty() || base::IsLink(manifest) ||
      !base::PathExists(manifest) || base::DirectoryExists(manifest))
    return UnpackedFolderStatus::kInvalid;
  base::FilePath relative;
  if (!folder.AppendRelativePath(manifest, &relative) || relative.empty() ||
      relative.ReferencesParent())
    return UnpackedFolderStatus::kInvalid;
  const std::optional<base::DictValue> parsed = ReadManifest(manifest);
  if (!parsed || !ManifestIsVersion3(*parsed))
    return UnpackedFolderStatus::kInvalid;
  if (resolved)
    *resolved = folder;
  return UnpackedFolderStatus::kOk;
}

UnpackedFolderStatus InspectUnpackedFolder(const base::FilePath& path) {
  base::FilePath resolved;
  return InspectUnpackedFolder(path, &resolved);
}

std::optional<std::string_view> InstallPromptEventType(int prompt_type) {
  switch (prompt_type) {
    case extensions::InstallPromptData::INSTALL_PROMPT:
    case extensions::InstallPromptData::EXTERNAL_INSTALL_PROMPT:
    case extensions::InstallPromptData::REMOTE_INSTALL_PROMPT:
      return "install";
    case extensions::InstallPromptData::RE_ENABLE_PROMPT:
      return "re-enable";
    case extensions::InstallPromptData::PERMISSIONS_PROMPT:
      return "permissions";
    case extensions::InstallPromptData::REPAIR_PROMPT:
      return "repair";
    default:
      return std::nullopt;
  }
}

bool DeveloperModePayloadValid(const base::DictValue& input) {
  return HasOnlyKeys(input, {"schemaVersion", "action", "enabled"}) &&
         input.FindBool("enabled").has_value();
}

bool UnpackedPayloadValid(const base::DictValue& input) {
  const std::string* path = input.FindString("path");
  if (!path || path->empty() || path->size() > 4096)
    return false;
  if (input.FindString("tabId")) {
    const std::string* tab_id = input.FindString("tabId");
    if (tab_id->empty() || tab_id->size() > 128)
      return false;
    return HasOnlyKeys(input, {"schemaVersion", "action", "path", "tabId"});
  }
  if (input.contains("tabId"))
    return false;
  return HasOnlyKeys(input, {"schemaVersion", "action", "path"});
}

bool SiteAccessPayloadValid(const base::DictValue& input) {
  const std::string* id = input.FindString("extensionId");
  const std::string* access = input.FindString("access");
  const std::string* origin = input.FindString("origin");
  if (!HasOnlyKeys(input, {"schemaVersion", "action", "extensionId", "access",
                           "origin"}) ||
      !id || !ExtensionIdIsAcceptable(*id) || !access || !origin)
    return false;
  return SiteAccessValue(*access).has_value() && OriginPayload(*origin);
}

shaar_error_code ApplyDeveloperMode(Profile* profile,
                                    bool enabled,
                                    shaar_reply_fn reply,
                                    void* reply_context,
                                    shaar_request_id request_id,
                                    shaar_error* error) {
  (void)error;
  PrefService* prefs = profile ? profile->GetPrefs() : nullptr;
  if (!prefs || !prefs->FindPreference(prefs::kExtensionsUIDeveloperMode)) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_NOT_READY);
    return SHAAR_OK;
  }
  prefs->SetBoolean(prefs::kExtensionsUIDeveloperMode, enabled);
  ReplyUpdated(reply, reply_context, request_id);
  return SHAAR_OK;
}

shaar_error_code BeginUnpackedLoad(ShaarEngineContext* context,
                                   shaar_engine* engine,
                                   shaar_window* window,
                                   shaar_tab* tab,
                                   Profile* profile,
                                   const base::DictValue& input,
                                   shaar_reply_fn reply,
                                   void* reply_context,
                                   shaar_request_id request_id,
                                   shaar_error* error) {
  if (!DeveloperModeEnabled(profile)) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_POLICY_BLOCKED);
    return SHAAR_OK;
  }
  const std::string* path_text = input.FindString("path");
  if (!path_text)
    return Fail(SHAAR_INVALID_ARGUMENT, "invalid unpacked extension request",
                error);
  const base::FilePath path = base::FilePath::FromUTF8Unsafe(*path_text);
  base::FilePath unpacked;
  if (InspectUnpackedFolder(path, &unpacked) != UnpackedFolderStatus::kOk) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_IO_ERROR);
    return SHAAR_OK;
  }
  const std::optional<base::DictValue> manifest =
      ReadManifest(unpacked.AppendASCII("manifest.json"));
  if (!manifest || !ManifestIsVersion3(*manifest)) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_IO_ERROR);
    return SHAAR_OK;
  }
  const std::string extension_id =
      crx_file::id_util::GenerateIdForPath(unpacked);
  if (!ExtensionIdIsAcceptable(extension_id) ||
      Pending().size() >= kMaxPendingInstalls) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_NOT_READY);
    return SHAAR_OK;
  }
  content::WebContents* contents = nullptr;
  auto identity = BindSelectedPage(context, engine, window, tab, &contents);
  if (!identity || !contents) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_NOT_READY);
    return SHAAR_OK;
  }
  const std::string* requested_tab = input.FindString("tabId");
  if (requested_tab && *requested_tab != identity->tab_id) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_WRONG_PROFILE);
    return SHAAR_OK;
  }

  const std::string id = std::to_string(++NextRequestID());
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "installRequested");
  payload.Set("type", "install");
  payload.Set("requestId", id);
  payload.Set("id", extension_id);
  payload.Set("name", *manifest->FindString("name"));
  payload.Set("version", *manifest->FindString("version"));
  payload.Set("sourceURL", contents->GetLastCommittedURL().spec());
  AddPermissionList(&payload, "permissions",
                    StringList(*manifest, "permissions"));
  AddPermissionList(&payload, "hostPermissions",
                    StringList(*manifest, "host_permissions"));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_CHROMIUM_ERROR);
    return SHAAR_OK;
  }

  PendingInstall pending;
  pending.kind = PendingInstall::Kind::kUnpacked;
  pending.engine = engine;
  pending.window = identity->window;
  pending.tab = identity->tab;
  pending.profile_id = identity->profile_id;
  pending.window_id = identity->window_id;
  pending.tab_id = identity->tab_id;
  pending.page_url = contents->GetLastCommittedURL();
  pending.unpacked_path = unpacked;
  Pending().emplace(id, std::move(pending));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&DropPending, id), base::Minutes(2));
  if (!EmitForEngine(engine, *identity, json)) {
    DropPending(id);
    ReplyRefused(reply, reply_context, request_id, SHAAR_NOT_READY);
    return SHAAR_OK;
  }
  Reply(reply, reply_context, request_id, SHAAR_OK,
        "{\"schemaVersion\":1,\"prompted\":true}");
  return SHAAR_OK;
}

shaar_error_code ApplySiteAccess(ShaarEngineContext* context,
                                 shaar_engine* engine,
                                 shaar_window* window,
                                 shaar_tab* tab,
                                 Profile* profile,
                                 const base::DictValue& input,
                                 shaar_reply_fn reply,
                                 void* reply_context,
                                 shaar_request_id request_id,
                                 shaar_error* error) {
  (void)error;
  const std::string* extension_id = input.FindString("extensionId");
  const std::string* access_text = input.FindString("access");
  const std::string* origin_text = input.FindString("origin");
  const auto access =
      access_text ? SiteAccessValue(*access_text) : std::nullopt;
  if (!extension_id || !access || !origin_text) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_POLICY_BLOCKED);
    return SHAAR_OK;
  }
  content::WebContents* contents = nullptr;
  auto identity = BindSelectedPage(context, engine, window, tab, &contents);
  if (!identity || !contents) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_NOT_READY);
    return SHAAR_OK;
  }
  const url::Origin expected = url::Origin::Create(GURL(*origin_text));
  const url::Origin actual =
      url::Origin::Create(contents->GetLastCommittedURL());
  if (!expected.IsSameOriginWith(actual)) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_WRONG_PROFILE);
    return SHAAR_OK;
  }
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  const extensions::Extension* extension =
      registry ? registry->GetExtensionById(
                     *extension_id, extensions::ExtensionRegistry::EVERYTHING)
               : nullptr;
  auto* permissions = extensions::PermissionsManager::Get(profile);
  const extensions::PermissionsData* permissions_data =
      extension ? extension->permissions_data() : nullptr;
  const GURL page = contents->GetLastCommittedURL();
  // UpdateSiteAccess CHECKs these. Refuse instead of terminating the process.
  if (!extension || !permissions_data || !permissions ||
      permissions_data->IsRestrictedUrl(page, nullptr) ||
      !permissions->CanAffectExtension(*extension) ||
      !permissions->CanUserSelectSiteAccess(*extension, page, *access)) {
    ReplyRefused(reply, reply_context, request_id, SHAAR_POLICY_BLOCKED);
    return SHAAR_OK;
  }
  extensions::SitePermissionsHelper(profile).UpdateSiteAccess(
      *extension, contents, *access, expected);
  ReplyUpdated(reply, reply_context, request_id);
  return SHAAR_OK;
}

shaar_error_code ResolveInstallDecision(ShaarEngineContext* context,
                                        shaar_engine* engine,
                                        shaar_window* window,
                                        shaar_tab* tab,
                                        Profile* profile,
                                        std::string_view profile_id,
                                        std::string_view request_id,
                                        bool accepted,
                                        shaar_reply_fn reply,
                                        void* reply_context,
                                        shaar_request_id abi_request,
                                        shaar_error* error) {
  auto found = Pending().find(std::string(request_id));
  if (found == Pending().end() || found->second.engine != engine)
    return Fail(SHAAR_NOT_FOUND, "extension install request was not found",
                error);
  PendingInstall pending = std::move(found->second);
  Pending().erase(found);
  const bool same_tab = (!window || pending.window == window) &&
                        (!tab || pending.tab == tab) &&
                        profile_id == pending.profile_id;
  const bool current = same_tab && RequestStillCurrent(context, pending);
  if (!accepted || !current) {
    Decline(std::move(pending.done));
    Reply(reply, reply_context, abi_request, SHAAR_OK,
          "{\"schemaVersion\":1,\"installed\":false}");
    return SHAAR_OK;
  }
  if (pending.kind == PendingInstall::Kind::kDialog) {
    AcceptDialog(std::move(pending));
    Reply(reply, reply_context, abi_request, SHAAR_OK,
          "{\"schemaVersion\":1,\"installed\":true}");
    return SHAAR_OK;
  }
  base::FilePath unpacked;
  if (!DeveloperModeEnabled(profile) ||
      InspectUnpackedFolder(pending.unpacked_path, &unpacked) !=
          UnpackedFolderStatus::kOk) {
    Reply(reply, reply_context, abi_request, SHAAR_OK,
          "{\"schemaVersion\":1,\"installed\":false}");
    return SHAAR_OK;
  }
  StartUnpackedLoad(profile, unpacked);
  Reply(reply, reply_context, abi_request, SHAAR_OK,
        "{\"schemaVersion\":1,\"installed\":true}");
  return SHAAR_OK;
}

// Patch 0067 binds this when --shaar-embedder is set. The signature matches
// ExtensionInstallPrompt::ShowDialogCallback.
void ShaarShowInstallPrompt(
    std::unique_ptr<ExtensionInstallPromptShowParams> params,
    ExtensionInstallPrompt::DoneCallback done_callback,
    std::unique_ptr<extensions::InstallPromptData> prompt) {
  if (done_callback.is_null())
    return;
  const extensions::Extension* extension =
      prompt ? prompt->extension() : nullptr;
  const std::optional<std::string_view> type =
      prompt ? InstallPromptEventType(static_cast<int>(prompt->type()))
             : std::nullopt;
  content::WebContents* contents =
      params ? params->GetParentWebContents() : nullptr;
  shaar_engine* engine = lifecycle::ActiveEngine();
  auto identity = contents ? windows_tabs::Registry().FindSelectedRegularTab(
                                 engine, contents)
                           : std::nullopt;
  const GURL page = contents ? contents->GetLastCommittedURL() : GURL();
  const bool named = extension && ExtensionIdIsAcceptable(extension->id()) &&
                     type && TextFits(extension->name(), 1024) &&
                     TextFits(extension->version().GetString(), 128);
  if (!named || !identity || !PageCanHostInstall(page) ||
      !lifecycle::EngineIsReady(engine) ||
      Pending().size() >= kMaxPendingInstalls) {
    Decline(std::move(done_callback));
    return;
  }

  const std::string id = std::to_string(++NextRequestID());
  base::DictValue payload;
  payload.Set("schemaVersion", 1);
  payload.Set("kind", "installRequested");
  payload.Set("type", *type);
  payload.Set("requestId", id);
  payload.Set("id", extension->id());
  payload.Set("name", extension->name());
  payload.Set("version", extension->version().GetString());
  payload.Set("sourceURL", page.spec());
  base::ListValue permissions;
  for (size_t index = 0; index < prompt->GetPermissionCount(); ++index) {
    if (permissions.size() >= kMaxListedPermissions)
      break;
    const std::string text = base::UTF16ToUTF8(prompt->GetPermission(index));
    if (text.empty() || text.size() > kMaxPermissionBytes)
      continue;
    permissions.Append(text);
  }
  AddPermissionList(&payload, "permissions", std::move(permissions));
  std::string json;
  if (!base::JSONWriter::Write(payload, &json)) {
    Decline(std::move(done_callback));
    return;
  }

  PendingInstall pending;
  pending.kind = PendingInstall::Kind::kDialog;
  pending.engine = engine;
  pending.window = identity->window;
  pending.tab = identity->tab;
  pending.profile_id = identity->profile_id;
  pending.window_id = identity->window_id;
  pending.tab_id = identity->tab_id;
  pending.page_url = page;
  pending.withhold_on_accept =
      prompt->ShouldWithheldPermissionsOnDialogAccept();
  pending.done = std::move(done_callback);
  Pending().emplace(id, std::move(pending));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&DropPending, id), base::Minutes(2));
  if (!EmitForEngine(engine, *identity, json))
    DropPending(id);
}

}  // namespace shaar::extensions_host
