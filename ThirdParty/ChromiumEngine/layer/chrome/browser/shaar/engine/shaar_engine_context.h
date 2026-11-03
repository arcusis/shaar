// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
#define CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_

#include <string_view>
#include <unordered_map>

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

// Resolves a private handle through the owning private-session registry. Find
// needs both IDs to attribute result events without exposing the query.
// BEGIN find
class PrivateSessionServices {
 public:
  virtual ~PrivateSessionServices() = default;
  virtual bool Resolve(shaar_engine* engine,
                       shaar_private_session* handle,
                       Profile** parent,
                       Profile** otr,
                       std::string_view* profile_id,
                       std::string_view* session_id) = 0;
};
// END find

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
  // BEGIN find
  virtual std::string_view WindowID(shaar_engine* engine,
                                    shaar_window* window) = 0;
  // END find
  virtual std::string_view TabID(shaar_engine* engine,
                                 shaar_window* window,
                                 shaar_tab* tab) = 0;
  virtual void GetTabs(
      shaar_engine* engine,
      shaar_window* window,
      std::unordered_map<std::string, content::WebContents*>* tabs) = 0;
};

struct ShaarEngineContext {
  ProfileServices* profile_services = nullptr;
  BrowserTabRegistry* browser_tabs = nullptr;
  // BEGIN find
  PrivateSessionServices* private_session_services = nullptr;
  // END find
};

ShaarEngineContext& EngineContext();
void SetProfileServices(ProfileServices* services);
void SetBrowserTabRegistry(BrowserTabRegistry* registry);
// BEGIN find
void SetPrivateSessionServices(PrivateSessionServices* services);
// END find

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
