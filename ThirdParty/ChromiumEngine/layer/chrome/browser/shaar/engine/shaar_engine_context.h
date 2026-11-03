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

struct ShaarEngineContext;

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
  // BEGIN media
  // The batch-2 window handle has no ID accessor yet; registries that carry
  // stable window identities override this when that lifecycle surface lands.
  virtual std::string_view WindowID(shaar_engine*, shaar_window*) { return {}; }
  // END media
};

// BEGIN media
// Optional hooks for media operations whose ownership lives outside the
// public Chromium session API. The implementation must validate OTR handle,
// window, tab, frame and prompt ownership before accepting a request.
class MediaRuntimeServices {
 public:
  virtual ~MediaRuntimeServices() = default;
  virtual void ObserveMediaTab(ShaarEngineContext* context,
                               shaar_engine* engine,
                               shaar_scope scope,
                               shaar_window* window,
                               shaar_tab* tab,
                               content::WebContents* contents) = 0;
  virtual bool OwnsPrivateTab(shaar_engine* engine,
                              ShaarEngineContext* context,
                              shaar_scope scope,
                              shaar_window* window,
                              shaar_tab* tab,
                              content::WebContents* contents) = 0;
  virtual shaar_error_code SubmitSupplementalOperation(
      ShaarEngineContext* context,
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
  // BEGIN media
  MediaRuntimeServices* media_services = nullptr;
  // END media
};

ShaarEngineContext& EngineContext();
void SetProfileServices(ProfileServices* services);
void SetBrowserTabRegistry(BrowserTabRegistry* registry);
// BEGIN media
void SetMediaRuntimeServices(MediaRuntimeServices* services);
// END media

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_ENGINE_SHAAR_ENGINE_CONTEXT_H_
