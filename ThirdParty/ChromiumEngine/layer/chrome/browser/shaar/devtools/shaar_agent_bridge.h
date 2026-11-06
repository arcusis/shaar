// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_AGENT_BRIDGE_H_
#define CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_AGENT_BRIDGE_H_

#include <string>
#include <string_view>

#include "chrome/browser/shaar/public/shaar_engine.h"
#include "chrome/browser/shaar/engine/shaar_engine_context.h"

namespace content {
class WebContents;
}

namespace shaar::agent_bridge {

bool AllowsPageMethod(std::string_view method);
bool IsBearerToken(std::string_view authorization);
bool IsBoundTarget(std::string_view requested, std::string_view granted);
std::string GenerateBearerToken();
bool HasActiveGrantForTesting();

shaar_error_code HandleOperation(shaar_engine* engine,
                                 shaar_scope scope,
                                 shaar_window* window,
                                 shaar_tab* tab,
                                 content::WebContents* contents,
                                 const DevToolsTargetIdentity& identity,
                                 shaar_operation operation,
                                 shaar_request_id request_id,
                                 shaar_reply_fn reply,
                                 void* reply_context,
                                 shaar_error* error);

void RevokeForEngine(shaar_engine* engine);
void RevokeForProfile(shaar_engine* engine, shaar_profile* profile);
void RevokeForWindow(shaar_engine* engine, shaar_window* window);
void RevokeForTab(shaar_engine* engine, shaar_tab* tab);

}  // namespace shaar::agent_bridge

#endif  // CHROME_BROWSER_SHAAR_DEVTOOLS_SHAAR_AGENT_BRIDGE_H_
