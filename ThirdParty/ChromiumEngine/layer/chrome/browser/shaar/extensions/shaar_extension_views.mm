// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

#import <AppKit/AppKit.h>

#include <pthread.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/uuid.h"
#include "chrome/browser/extensions/component_loader.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/extensions/extension_view_host_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_event_bridge.h"
#include "chrome/browser/shaar/lifecycle/shaar_lifecycle.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"
#include "chrome/browser/ui/browser.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"

namespace {

constexpr char kManagerID[] = "bphhlegomeaogfihjcipdbcfbgkcfafp";
struct FrameworkDevToolsBundle {
  const char* name;
  const char* id;
};
constexpr FrameworkDevToolsBundle kFrameworkDevTools[] = {
    {"react", "fmkadmapgofadopljbjfkapdkoienihi"},
    {"vue", "nhdogjmejiglipccpnnnanhbledajbpd"},
    {"angular", "ienfalfjdbdpebioblfackkekamfmbnh"},
};
thread_local std::string g_probe_extension_id;

shaar_error_code ProbeFailure(shaar_error_code code, const char* message,
                              shaar_error* error) {
  if (error) {
    const uint32_t size = error->size;
    if (size >= offsetof(shaar_error, code) + sizeof(error->code))
      error->code = code;
    if (size >= offsetof(shaar_error, platform_code) + sizeof(error->platform_code))
      error->platform_code = 0;
    if (size >= offsetof(shaar_error, message) + sizeof(error->message))
      error->message = {message, std::strlen(message)};
  }
  return code;
}

class EmbeddedExtensionView final : public extensions::ExtensionView {
 public:
  explicit EmbeddedExtensionView(extensions::ExtensionViewHost* host)
      : host_(host) {}

  gfx::NativeView GetNativeView() override {
    return host_->host_contents()->GetNativeView();
  }
  void ResizeDueToAutoResize(content::WebContents*,
                             const gfx::Size& size) override {
    NSView* view = GetNativeView().GetNativeNSView();
    [view setFrameSize:NSMakeSize(size.width(), size.height())];
  }
  void RenderFrameCreated(content::RenderFrameHost*) override {}
  bool HandleKeyboardEvent(content::WebContents*,
                           const input::NativeWebKeyboardEvent&) override {
    return false;
  }
  void OnLoaded() override {}

 private:
  extensions::ExtensionViewHost* host_;
};

struct PopupHost {
  shaar_engine* engine;
  shaar_profile* profile;
  shaar_window* window;
  shaar_tab* owner_tab;
  Browser* browser;
  std::unique_ptr<EmbeddedExtensionView> view;
  std::unique_ptr<extensions::ExtensionViewHost> host;
};

std::unordered_map<std::string, PopupHost>& Popups() {
  static std::unordered_map<std::string, PopupHost> popups;
  return popups;
}

bool OwnedWindow(shaar_engine* engine, shaar_window* window) {
  return engine && window &&
         shaar::windows_tabs::Registry().FindWindowOwner(window) == engine;
}

}  // namespace

namespace shaar::extensions_host {

bool ValidProbeExtensionPath(const base::FilePath& data_root,
                             const base::FilePath& requested) {
  const base::FilePath canonical_data = base::MakeAbsoluteFilePath(data_root);
  const base::FilePath canonical_path = base::MakeAbsoluteFilePath(requested);
  if (canonical_data.empty() || canonical_path.empty())
    return false;
  const base::FilePath root = canonical_data.DirName();
  if (root.BaseName().value().rfind("arcusis-engine-probe-", 0) != 0 ||
      canonical_data != root.Append("Chromium") ||
      canonical_path != root.Append("Extension") ||
      !base::DirectoryExists(canonical_path))
    return false;
  std::string marker;
  return base::ReadFileToString(root.Append(".arcusis-probe"), &marker) &&
         marker == "arcusis-engine-probe-v1\n";
}

bool ValidPopupOrigin(std::string_view extension_id, const GURL& url) {
  return url.is_valid() && url.SchemeIs("chrome-extension") &&
         url.host() == extension_id && !url.has_username() &&
         !url.has_password() && !url.has_port();
}

std::optional<std::string> OpenPopup(shaar_engine* engine,
                                     shaar_profile* profile_handle,
                                     shaar_window* window,
                                     shaar_tab* tab,
                                     Browser* browser,
                                     Profile* profile,
                                     const extensions::Extension& extension,
                                     const GURL& url) {
  if (!OwnedWindow(engine, window) || !profile_handle || !browser ||
      browser->GetProfile() != profile ||
      !ValidPopupOrigin(extension.id(), url))
    return std::nullopt;
  auto host = extensions::ExtensionViewHostFactory::CreatePopupHost(
      extension, url, browser);
  if (!host || !host->host_contents() ||
      host->host_contents()->GetBrowserContext() != profile)
    return std::nullopt;
  auto view = std::make_unique<EmbeddedExtensionView>(host.get());
  host->set_view(view.get());
  std::string popup_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  auto [entry, inserted] = Popups().emplace(
      popup_id, PopupHost{engine, profile_handle, window, tab, browser,
                          std::move(view), std::move(host)});
  if (!inserted)
    return std::nullopt;
  entry->second.host->CreateRendererSoon();
  return popup_id;
}

bool ClosePopup(shaar_engine* engine,
                shaar_profile* profile,
                std::string_view popup_id) {
  auto entry = Popups().find(std::string(popup_id));
  if (entry == Popups().end() || entry->second.engine != engine ||
      entry->second.profile != profile)
    return false;
  Popups().erase(entry);
  return true;
}

bool RegisterBundledManager(Profile* profile) {
  if (!profile || profile->IsOffTheRecord())
    return false;
  NSString* path = [[NSBundle mainBundle] pathForResource:@"ExtensionManager"
                                                   ofType:nil];
  if (!path)
    return false;
  auto* loader = extensions::ComponentLoader::Get(profile);
  if (!loader)
    return false;
  if (loader->Exists(kManagerID))
    return true;
  return loader->AddOrReplace(
             base::FilePath::FromUTF8Unsafe(path.UTF8String)) == kManagerID;
}

std::string_view FrameworkDevToolsID(std::string_view name) {
  for (const auto& bundle : kFrameworkDevTools) {
    if (name == bundle.name)
      return bundle.id;
  }
  return {};
}

bool ValidFrameworkDevToolsPath(const base::FilePath& root,
                                const base::FilePath& requested) {
  const base::FilePath canonical_root = base::MakeAbsoluteFilePath(root);
  const base::FilePath canonical_path = base::MakeAbsoluteFilePath(requested);
  return !canonical_root.empty() && !canonical_path.empty() &&
         !base::IsLink(requested) &&
         canonical_path.DirName() == canonical_root &&
         FrameworkDevToolsID(canonical_path.BaseName().AsUTF8Unsafe()).size() &&
         base::DirectoryExists(canonical_path);
}

bool FrameworkDevToolsManifestIsLocal(std::string_view manifest) {
  auto parsed = base::JSONReader::Read(manifest, base::JSON_PARSE_RFC);
  if (!parsed || !parsed->is_dict())
    return false;
  const auto allowed_match = [](const base::Value& value) {
    if (!value.is_string())
      return false;
    const std::string& match = value.GetString();
    return match == "http://localhost/*" ||
           match == "https://localhost/*" ||
           match == "http://127.0.0.1/*" ||
           match == "https://127.0.0.1/*";
  };
  const auto allowed_matches = [&](const base::Value::List* matches) {
    if (!matches || matches->empty())
      return false;
    for (const auto& match : *matches) {
      if (!allowed_match(match))
        return false;
    }
    return true;
  };
  const auto& dict = parsed->GetDict();
  if (!allowed_matches(dict.FindList("host_permissions")) ||
      dict.contains("optional_host_permissions"))
    return false;
  for (const char* field : {"content_scripts", "web_accessible_resources"}) {
    const auto* entries = dict.FindList(field);
    if (!entries)
      return false;
    for (const auto& entry : *entries) {
      if (!entry.is_dict() ||
          !allowed_matches(entry.GetDict().FindList("matches")))
        return false;
    }
  }
  return true;
}

bool RegisterBundledFrameworkDevTools(Profile* profile, std::string* failure) {
  if (failure)
    failure->clear();
  if (!profile || profile->IsOffTheRecord()) {
    if (failure)
      *failure = "regularProfileRequired";
    return false;
  }
  NSString* resources = [[NSBundle mainBundle] resourcePath];
  auto* loader = extensions::ComponentLoader::Get(profile);
  if (!resources || !loader) {
    if (failure)
      *failure = "bundleOrLoaderUnavailable";
    return false;
  }
  const base::FilePath root =
      base::FilePath::FromUTF8Unsafe(resources.UTF8String)
          .Append("FrameworkDevTools");
  for (const auto& bundle : kFrameworkDevTools) {
    const base::FilePath path = root.Append(bundle.name);
    if (!ValidFrameworkDevToolsPath(root, path)) {
      if (failure)
        *failure = std::string(bundle.name) + "MissingOrUnsafe";
      return false;
    }
    std::string manifest;
    if (!base::ReadFileToString(path.Append("manifest.json"), &manifest) ||
        !FrameworkDevToolsManifestIsLocal(manifest)) {
      if (failure)
        *failure = std::string(bundle.name) + "ManifestUnsafe";
      return false;
    }
    if (loader->Exists(bundle.id))
      continue;
    if (loader->AddOrReplace(path) != bundle.id) {
      if (failure)
        *failure = std::string(bundle.name) + "IdentityMismatch";
      return false;
    }
  }
  return true;
}

void ClosePopupsForWindow(shaar_engine* engine, shaar_window* window) {
  for (auto it = Popups().begin(); it != Popups().end();) {
    if (it->second.engine == engine && it->second.window == window)
      it = Popups().erase(it);
    else
      ++it;
  }
}

void ClosePopupsForTab(shaar_engine* engine, shaar_tab* tab) {
  for (auto it = Popups().begin(); it != Popups().end();) {
    if (it->second.engine == engine && it->second.owner_tab == tab)
      it = Popups().erase(it);
    else
      ++it;
  }
}

void ClosePopupsForBrowser(shaar_engine* engine, Browser* browser) {
  for (auto it = Popups().begin(); it != Popups().end();) {
    if (it->second.engine == engine && it->second.browser == browser)
      it = Popups().erase(it);
    else
      ++it;
  }
}

}  // namespace shaar::extensions_host

extern "C" SHAAR_EXPORT shaar_error_code shaar_test_load_component_extension(
    shaar_engine* engine, shaar_profile* profile_handle, shaar_bytes path,
    shaar_bytes* extension_id, shaar_error* error) {
  if (extension_id) *extension_id = {};
  if (!engine || !profile_handle || !path.data || !path.size || !extension_id)
    return ProbeFailure(SHAAR_INVALID_ARGUMENT, "missing probe input", error);
  if (!pthread_main_np())
    return ProbeFailure(SHAAR_INVALID_ARGUMENT, "main thread required", error);
  if (!shaar::lifecycle::EngineIsReady(engine))
    return ProbeFailure(SHAAR_NOT_READY, "engine is not ready", error);
  const char* testing = std::getenv("SHAAR_ENGINE_TESTING");
  if (!testing || std::strcmp(testing, "1") != 0)
    return ProbeFailure(SHAAR_POLICY_BLOCKED, "verification mode required", error);
  std::string requested(path.data, path.size);
  if (requested.find('\0') != std::string::npos ||
      !shaar::extensions_host::ValidProbeExtensionPath(
          base::FilePath::FromUTF8Unsafe(engine->data_root),
          base::FilePath::FromUTF8Unsafe(requested)))
    return ProbeFailure(SHAAR_POLICY_BLOCKED, "foreign probe extension path", error);
  auto* services = shaar::EngineContext().profile_services;
  Profile* profile = services ? services->ResolveProfile(engine, profile_handle) : nullptr;
  if (!profile || profile->IsOffTheRecord())
    return ProbeFailure(SHAAR_WRONG_PROFILE, "regular probe profile required", error);
  auto* loader = extensions::ComponentLoader::Get(profile);
  if (!loader)
    return ProbeFailure(SHAAR_NOT_READY, "component loader unavailable", error);
  g_probe_extension_id = loader->AddOrReplace(
      base::FilePath::FromUTF8Unsafe(requested));
  if (g_probe_extension_id.empty())
    return ProbeFailure(SHAAR_CHROMIUM_ERROR, "probe component failed to load", error);
  *extension_id = {g_probe_extension_id.data(), g_probe_extension_id.size()};
  return ProbeFailure(SHAAR_OK, "", error);
}

extern "C" SHAAR_EXPORT void* shaar_extension_popup_view(shaar_engine* engine,
                                                         shaar_window* window,
                                                         shaar_bytes popup_id) {
  if (!pthread_main_np() || !OwnedWindow(engine, window) || !popup_id.data ||
      !popup_id.size)
    return nullptr;
  auto entry = Popups().find(std::string(popup_id.data, popup_id.size));
  if (entry == Popups().end() || entry->second.engine != engine ||
      entry->second.window != window)
    return nullptr;
  shaar_tab* tab = entry->second.owner_tab;
  if (tab && shaar::windows_tabs::Registry().FindTabWindow(tab) != window) {
    Popups().erase(entry);
    return nullptr;
  }
  NSView* view =
      entry->second.host->host_contents()->GetNativeView().GetNativeNSView();
  return (__bridge void*)view;
}
