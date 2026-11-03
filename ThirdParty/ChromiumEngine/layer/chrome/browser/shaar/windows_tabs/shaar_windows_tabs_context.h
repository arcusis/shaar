// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_CONTEXT_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_CONTEXT_H_

#include <string>
#include <unordered_map>

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

class TabStripModel;
class Browser;
namespace ui {
class BaseWindow;
}
namespace content {
class WebContents;
}

namespace shaar {

using WindowRequestResolver = shaar_error_code (*)(
    void* context,
    shaar_request_id request_id,
    const shaar_scope* scope,
    shaar_window* window,
    bool accepted);
using TabActivationResolver = shaar_error_code (*)(
    void* context,
    shaar_request_id request_id,
    const shaar_scope* scope,
    shaar_window* window,
    shaar_tab* tab,
    bool accepted);

struct ModuleCall {
  shaar_engine* engine;
  shaar_scope scope;
  shaar_window* window;
  shaar_tab* tab;
  std::string tab_id;
  shaar_operation operation;
  shaar_bytes args_json;
  shaar_request_id request_id;
  shaar_reply_fn reply;
  void* reply_context;
  TabStripModel* tab_strip_model;
  const std::unordered_map<std::string, content::WebContents*>* bound_tabs;
  const char* scope_profile_id;
  Browser* scoped_browser;
  ui::BaseWindow* native_window;
  Browser** active_browser;
  std::string* active_profile_id;
  std::unordered_map<std::string, Browser*>* browsers_by_profile;
  // Lifecycle supplies these callbacks from its pending-request registry.
  // A resolver validates request ownership and consumes a request exactly once.
  void* request_registry_context;
  WindowRequestResolver resolve_window_request;
  TabActivationResolver resolve_tab_activation;
};

using ModuleHandler = shaar_error_code (*)(const ModuleCall*, shaar_error*);
}  // namespace shaar

extern "C" void shaar_windows_tabs_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_CONTEXT_H_
