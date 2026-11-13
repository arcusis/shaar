// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_H_
#define CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_H_

#include <string>
#include <string_view>

#include "base/memory/scoped_refptr.h"
#include "base/functional/callback_helpers.h"

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace base {
class Value;
}
namespace content {
class DevToolsAgentHost;
class WebContents;
}
class GURL;
class Profile;

namespace shaar::devtools {

struct ModuleHandlers {
  ShaarModuleRegistry::Handler handle_operation;
};

void BindRuntimeServices();

// Retain a Node agent host until the app opens the requested owned tab, then
// attach the frontend bindings to that host. No Chromium Browser is created.
bool RequestNodeFrontend(Profile* profile,
                         content::WebContents* source,
                         const GURL& url,
                         scoped_refptr<content::DevToolsAgentHost> host);
bool HasPendingNodeFrontend(Profile* profile, const GURL& url);
bool OpenPendingNodeFrontend(content::WebContents* contents,
                             Profile* profile,
                             const GURL& url);

// Keeps the native window hidden while temporarily showing the page to the
// renderer for capture. The guard restores the previous page visibility.
base::ScopedClosureRunner StartHiddenProbeCapture(content::WebContents* contents);

// Returns a fixed protocol method only when the command belongs to the
// requested capability. Cookie commands are restricted to Developer.
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
// Strict testing-only click schema and policy. Selectors are fixture element IDs.
bool ParseProbeClickArguments(shaar_bytes args_json,
                              int* x,
                              int* y,
                              std::string* element_id);
bool ParseProbeScrollArguments(shaar_bytes args_json, std::string* element_id);
bool ParseNodeProbePort(shaar_bytes args_json, int* port);
bool ParseProbePopupArguments(shaar_bytes args_json, bool evaluate,
                              std::string* popup_id, std::string* expression);
bool ProbeWindowAllowed(bool testing, bool owned_root, bool selected,
                       bool never_shown, const GURL& url);
void EmitFrontendStateEvent(shaar_engine* engine,
                            const DevToolsTargetIdentity& identity,
                            bool open);

// Validates the versioned ABI envelope and serializes a protocol request.
shaar_error_code EncodeProtocolRequest(shaar_bytes args_json,
                                       shaar_request_id request_id,
                                       std::string* request_json,
                                       std::string* reason);

// Starts the same protocol client used by the operation handler. The host is
// supplied by the caller so its attachment and reply path can be tested
// without constructing a browser window.
bool StartProtocolRequest(scoped_refptr<content::DevToolsAgentHost> host,
                          shaar_request_id request_id,
                          shaar_reply_fn reply,
                          void* reply_context,
                          const std::string& request_json,
                          std::string main_frame_id = {},
                          base::ScopedClosureRunner visibility_lease = {});

// Closes a synthetic target that does not emit AgentHostClosed in tests.
void CloseProtocolSessionForTesting(content::DevToolsAgentHost* host);

// Selects the page protocol target for the scoped tab, including OTR tabs.
scoped_refptr<content::DevToolsAgentHost> ProtocolAgentHostFor(
    content::WebContents* contents);
bool IsProtocolPageTargetFor(content::WebContents* contents,
                             content::DevToolsAgentHost* host);

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
