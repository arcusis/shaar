// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_H_
#define CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_H_

#include <string>
#include <string_view>

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace base {
class Value;
}

namespace shaar::devtools {

struct ModuleHandlers {
  ShaarModuleRegistry::Handler handle_operation;
};

// Returns a fixed protocol method only when the command belongs to the
// requested capability. Cookie commands are reserved for site-data.
const char* ProtocolMethod(shaar_devtools_capability capability,
                           shaar_devtools_command command);

bool IsValidTargetIdentity(shaar_scope scope,
                           std::string_view registered_tab_id,
                           const DevToolsTargetIdentity& identity);
bool PolicyAllowsOperation(DevToolsRuntimeServices* runtime,
                           shaar_engine* engine,
                           shaar_scope scope,
                           content::WebContents* contents,
                           shaar_operation operation,
                           int capability);
shaar_error_code CancelDevToolsRequest(shaar_engine* engine,
                                       shaar_request_id request_id,
                                       shaar_error* error);
void InstallContextRuntimeServices();
void EmitFrontendStateEvent(shaar_engine* engine,
                            const DevToolsTargetIdentity& identity,
                            bool open,
                            uint32_t dock_side,
                            int extent);

// Validates the versioned ABI envelope and serializes a protocol request.
shaar_error_code EncodeProtocolRequest(shaar_bytes args_json,
                                       shaar_request_id request_id,
                                       std::string* request_json,
                                       std::string* reason);

shaar_error_code HandleDevToolsOperation(
    shaar::ShaarEngineContext* context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* error);

}  // namespace shaar::devtools

extern "C" void shaar_devtools_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_H_
