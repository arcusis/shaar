// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_
#define CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "chrome/browser/shaar/public/shaar_engine.h"
#include "components/permissions/permission_prompt.h"

namespace shaar::permissions {

// Token and navigation captured for the frame that asked. The live snapshot
// must still be that frame, active, and inside the same tab.
struct FrameSnapshot {
  std::string token;
  bool active = false;
  bool same_contents = false;
  int64_t navigation_id = 0;
};

inline bool FrameStillBound(const FrameSnapshot& stored,
                            const FrameSnapshot& live) {
  if (stored.token.empty())
    return false;
  return stored.token == live.token && live.active && live.same_contents &&
         stored.navigation_id == live.navigation_id;
}

// Private profiles do not keep a grant in the parent profile. A private
// protocol handler cannot use AcceptThisTime (that decision is forbidden),
// so it is accepted onto the off-the-record registry, which does not persist.
enum class GrantPersistence {
  kDeny,
  kThisVisit,
  kProfile,
  kPrivateProtocol,
};

inline GrantPersistence PersistenceFor(bool allowed,
                                       bool current,
                                       bool private_profile,
                                       bool one_time,
                                       bool protocol_handler) {
  if (!allowed || !current)
    return GrantPersistence::kDeny;
  if (protocol_handler && private_profile)
    return GrantPersistence::kPrivateProtocol;
  if (one_time || private_profile)
    return GrantPersistence::kThisVisit;
  return GrantPersistence::kProfile;
}

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
