// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_VIEWPORTS_H_
#define CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_VIEWPORTS_H_

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace content {
class WebContents;
}

namespace shaar::devtools {

void CloseViewportLeaseForTab(content::WebContents* contents);
void CloseViewportLeasesForEngine(shaar_engine* engine);

shaar_error_code HandleViewportOperation(
    ShaarEngineContext* context, shaar_engine* engine, shaar_scope scope,
    shaar_window* window, shaar_tab* tab, content::WebContents* contents,
    const DevToolsTargetIdentity& identity, shaar_operation operation,
    shaar_bytes args_json, shaar_request_id request_id, shaar_reply_fn reply,
    void* reply_context, shaar_error* error);

}  // namespace shaar::devtools

#endif  // CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_DEVTOOLS_VIEWPORTS_H_
