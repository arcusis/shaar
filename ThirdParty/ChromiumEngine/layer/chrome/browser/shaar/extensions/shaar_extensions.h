// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_EXTENSIONS_SHAAR_EXTENSIONS_H_
#define CHROME_BROWSER_SHAAR_EXTENSIONS_SHAAR_EXTENSIONS_H_

#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

#include <optional>
#include <string>
#include <string_view>

class Browser;
class Profile;
class GURL;
namespace extensions {
class Extension;
}

namespace shaar {
struct ExtensionsModuleHandlers {
  ShaarModuleRegistry::Handler submit = nullptr;
};
}  // namespace shaar

shaar_error_code HandleExtensionsOperation(shaar::ShaarEngineContext*,
                                           shaar_engine*,
                                           shaar_scope,
                                           shaar_window*,
                                           shaar_tab*,
                                           shaar_operation,
                                           shaar_bytes,
                                           shaar_request_id,
                                           shaar_reply_fn,
                                           void*,
                                           shaar_error*);

bool SharedHomeVersionSatisfied(std::string_view installed,
                                std::string_view approved);

namespace shaar::extensions_host {
bool ValidPopupOrigin(std::string_view extension_id, const GURL& url);
std::optional<std::string> OpenPopup(shaar_engine*,
                                     shaar_profile*,
                                     shaar_window*,
                                     shaar_tab*,
                                     Browser*,
                                     Profile*,
                                     const extensions::Extension&,
                                     const GURL&);
bool ClosePopup(shaar_engine*, shaar_profile*, std::string_view);
bool RegisterBundledManager(Profile*);
void ClosePopupsForWindow(shaar_engine*, shaar_window*);
void ClosePopupsForTab(shaar_engine*, shaar_tab*);
void ClosePopupsForBrowser(shaar_engine*, Browser*);
}  // namespace shaar::extensions_host

extern "C" void shaar_extensions_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_EXTENSIONS_SHAAR_EXTENSIONS_H_
