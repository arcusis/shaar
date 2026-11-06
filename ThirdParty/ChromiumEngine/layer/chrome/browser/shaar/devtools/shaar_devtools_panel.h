// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
#ifndef CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_PANEL_H_
#define CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_PANEL_H_

#include "chrome/browser/shaar/devtools/shaar_devtools.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"

namespace shaar::devtools {

// Test seam for the same allowlist and payload encoder used by live leases.
bool ProjectPanelEventForTesting(std::string_view message, int lease_id,
                                 std::string* output);
void ClosePanelLeaseForTab(content::WebContents* contents);
void ClosePanelLeasesForEngine(shaar_engine* engine);

// A trusted, local panel owns one lease on exactly one tab. This entry point
// never grants remote DevTools access.
shaar_error_code HandlePanelOperation(
    ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, content::WebContents* contents,
    const DevToolsTargetIdentity& identity, shaar_operation operation,
    shaar_bytes args_json, shaar_request_id request_id, shaar_reply_fn reply,
    void* reply_context, shaar_error* error);

}  // namespace shaar::devtools
#endif  // CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_PANEL_H_
