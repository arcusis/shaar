// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_
#define CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_

#include <memory>
#include <optional>
#include <string_view>

#include "chrome/browser/shaar/public/shaar_engine.h"
#include "components/permissions/permission_prompt.h"

namespace shaar::permissions {

// Returns a prompt when every request maps to the shared website sheet.
// An unmapped or empty request returns nullptr so Chromium keeps its own path.
std::unique_ptr<::permissions::PermissionPrompt> CreateEmbedderPrompt(
    content::WebContents* contents,
    ::permissions::PermissionPrompt::Delegate* delegate);

// A missing id returns nullopt. A stale request is denied and returns false.
std::optional<bool> ResolveWebsitePermission(shaar_engine* engine,
                                             content::WebContents* contents,
                                             std::string_view request_id,
                                             bool accepted);

}  // namespace shaar::permissions

#endif  // CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_
