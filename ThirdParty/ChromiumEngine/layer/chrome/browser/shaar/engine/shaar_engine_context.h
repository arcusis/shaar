// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
#define CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_

#include <string_view>
#include <unordered_map>

// BEGIN devtools
#include <string>
// END devtools

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

// Site-data and find resolve private handles through the owning registry.
// Find also needs both IDs to attribute results without exposing the query.
// BEGIN site_data
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
// END site_data

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

// BEGIN devtools
// Resolved, copied identities used for DevTools policy and event envelopes.
// These strings must be stable for the duration of one UI-thread operation.
struct DevToolsTargetIdentity {
  std::string profile_id;
  std::string session_id;
  std::string window_id;
  std::string tab_id;
};

// DevTools runtime services bind the opaque ABI scope to the exact Chromium
// target, enforce app policy, and supply the public IDs used in events.
class DevToolsRuntimeServices {
 public:
  virtual ~DevToolsRuntimeServices() = default;
  virtual bool ResolveTarget(shaar_engine* engine,
                             shaar_scope scope,
                             shaar_window* window,
                             shaar_tab* tab,
                             content::WebContents* contents,
                             DevToolsTargetIdentity* identity) = 0;
  virtual bool IsOperationAllowed(shaar_engine* engine,
                                  shaar_scope scope,
                                  content::WebContents* contents,
                                  shaar_operation operation,
                                  int capability) = 0;
};
// END devtools
// BEGIN media
// Optional hooks for media operations whose ownership lives outside the
// public Chromium session API. The implementation must validate OTR handle,
// window, tab, frame and prompt ownership before accepting a request.
class MediaRuntimeServices {
 public:
  virtual ~MediaRuntimeServices() = default;
  virtual bool OwnsPrivateTab(shaar_engine* engine,
                              shaar_scope scope,
                              shaar_window* window,
                              shaar_tab* tab,
                              content::WebContents* contents) = 0;
  virtual shaar_error_code SubmitSupplementalOperation(
      shaar_engine* engine,
      shaar_scope scope,
      shaar_window* window,
      shaar_tab* tab,
      shaar_operation operation,
      shaar_bytes args_json,
      shaar_request_id request_id,
      shaar_reply_fn reply,
      void* reply_context,
      shaar_error* immediate_error) = 0;
};
// END media

struct ShaarEngineContext {
  ProfileServices* profile_services = nullptr;
  BrowserTabRegistry* browser_tabs = nullptr;
  // BEGIN site_data
  PrivateSessionServices* private_sessions = nullptr;
  // END site_data
  // BEGIN devtools
  DevToolsRuntimeServices* devtools_runtime = nullptr;
  // END devtools
  // BEGIN media
  MediaRuntimeServices* media_services = nullptr;
  // END media
};

ShaarEngineContext& EngineContext();
void SetProfileServices(ProfileServices* services);
void SetBrowserTabRegistry(BrowserTabRegistry* registry);
// BEGIN site_data
void SetPrivateSessionServices(PrivateSessionServices* services);
// END site_data
// BEGIN devtools
void SetDevToolsRuntimeServices(DevToolsRuntimeServices* services);
// END devtools
// BEGIN media
void SetMediaRuntimeServices(MediaRuntimeServices* services);
// END media

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
