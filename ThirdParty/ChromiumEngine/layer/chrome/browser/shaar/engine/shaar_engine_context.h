// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
#define CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_

#include <string_view>
#include <unordered_map>

// BEGIN extensions
#include <string>
// END extensions

#include "chrome/browser/shaar/public/shaar_engine.h"

class Browser;
class Profile;
class KeyedService;
namespace content {
class WebContents;
}

namespace shaar {

// Resolves public ABI profile handles only while they belong to the supplied
// engine. The keyed-service lookup goes through Chromium's profile factory so
// modules do not need to know how profiles are owned by the profiles module.
class ProfileServices {
 public:
  using KeyedServiceLookup = KeyedService* (*)(Profile* profile);
  virtual ~ProfileServices() = default;
  virtual Profile* ResolveProfile(shaar_engine* engine,
                                  shaar_profile* handle) = 0;
  virtual std::string_view ProfileID(shaar_engine* engine,
                                     shaar_profile* handle) = 0;
  virtual KeyedService* GetKeyedService(
      shaar_engine* engine,
      shaar_profile* handle,
      KeyedServiceLookup lookup) = 0;
};

// Resolves opaque ABI window and tab IDs to Chromium objects. Returned pointers
// are borrowed and valid on the UI sequence while their IDs remain registered.
class BrowserTabRegistry {
 public:
  virtual ~BrowserTabRegistry() = default;
  virtual Browser* FindBrowser(shaar_engine* engine,
                               shaar_window* window) = 0;
  virtual content::WebContents* FindWebContents(shaar_engine* engine,
                                                 shaar_window* window,
                                                 shaar_tab* tab) = 0;
  virtual content::WebContents* FindWebContentsByID(
      shaar_engine* engine,
      shaar_window* window,
      std::string_view tab_id) = 0;
  virtual std::string_view TabID(shaar_engine* engine,
                                 shaar_window* window,
                                 shaar_tab* tab) = 0;
  virtual void GetTabs(
      shaar_engine* engine,
      shaar_window* window,
      std::unordered_map<std::string, content::WebContents*>* tabs) = 0;
};

// BEGIN extensions
// Embedder-owned extension operations that require a host consent surface or
// native window. Chromium objects stay inside the browser layer; IDs remain
// bound to the exact profile/window/tab supplied by shaar_submit.
class ExtensionsRuntimeServices {
 public:
  virtual ~ExtensionsRuntimeServices() = default;
  // Successful BeginInstall means a consent request was created and emitted;
  // it does not claim that installation or profile fan-out has completed.
  virtual shaar_error_code BeginInstall(shaar_engine* engine,
                                        shaar_profile* profile,
                                        shaar_window* window,
                                        shaar_tab* tab,
                                        std::string_view extension_id,
                                        std::string_view source) = 0;
  virtual shaar_error_code ResolveInstallDecision(
      shaar_engine* engine,
      shaar_profile* profile,
      std::string_view request_id,
      bool accepted) = 0;
  virtual shaar_error_code InvokeAction(shaar_engine* engine,
                                        shaar_profile* profile,
                                        shaar_window* window,
                                        shaar_tab* tab,
                                        std::string_view extension_id,
                                        std::string* route) = 0;
  // Popup open/close/size events are emitted by the host as lifecycle changes.
  virtual shaar_error_code ClosePopup(shaar_engine* engine,
                                      shaar_profile* profile,
                                      shaar_window* window,
                                      std::string_view popup_id) = 0;
};
// END extensions

struct ShaarEngineContext {
  ProfileServices* profile_services = nullptr;
  BrowserTabRegistry* browser_tabs = nullptr;
  // BEGIN extensions
  ExtensionsRuntimeServices* extensions = nullptr;
  // END extensions
};

ShaarEngineContext& EngineContext();
void SetProfileServices(ProfileServices* services);
void SetBrowserTabRegistry(BrowserTabRegistry* registry);
// BEGIN extensions
void SetExtensionsRuntimeServices(ExtensionsRuntimeServices* services);
// END extensions

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
