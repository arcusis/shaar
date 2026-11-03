// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_MODULE_REGISTRY_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_MODULE_REGISTRY_H_

#include <string>
#include <unordered_map>

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
};

using ModuleHandler = shaar_error_code (*)(const ModuleCall*, shaar_error*);

// Temporary declaration until the lifecycle module's registry lands. It keeps
// the dispatcher independent of any particular engine implementation.
struct ShaarModuleRegistry {
  uint32_t size;
  void* context;
  void (*register_handler)(void* context,
                           shaar_operation operation,
                           ModuleHandler handler);
};

}  // namespace shaar

void shaar_windows_tabs_register(shaar::ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_MODULE_REGISTRY_H_
