// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_
#define CHROME_BROWSER_SHAAR_PERMISSIONS_SHAAR_PERMISSION_PROMPT_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "chrome/browser/shaar/public/shaar_engine.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/request_type.h"

namespace shaar::permissions {

// Maps Chromium website permission requests onto the app-owned consent kinds.
std::optional<std::string_view> PermissionKindForRequestType(
    ::permissions::RequestType type);

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

// A same-document navigation keeps the request. The asking frame ends it when
// that frame is deleted or a committed navigation replaces it. Another frame
// does not.
inline bool FrameLeftTheRequest(const FrameSnapshot& stored,
                                const FrameSnapshot& live,
                                bool same_document,
                                bool frame_deleted) {
  if (same_document || stored.token.empty() || stored.token != live.token)
    return false;
  return frame_deleted || !FrameStillBound(stored, live);
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

// Only a regular-profile Accept is written to the parent profile.
inline bool GrantIsPersisted(GrantPersistence persistence) {
  return persistence == GrantPersistence::kProfile;
}

inline bool ShownPermissionsMatch(const std::vector<std::string>& shown,
                                 const std::vector<std::string>& current) {
  std::vector<std::string> sorted_shown = shown;
  std::vector<std::string> sorted_current = current;
  std::sort(sorted_shown.begin(), sorted_shown.end());
  std::sort(sorted_current.begin(), sorted_current.end());
  return sorted_shown == sorted_current;
}

inline bool ShownRequestCountMatches(std::size_t shown, std::size_t current) {
  return shown == current;
}

GrantPersistence DecideGrant(
    ::permissions::PermissionPrompt::Delegate* delegate,
    bool allowed,
    bool current,
    bool private_profile,
    bool one_time,
    bool protocol_handler,
    const ::PromptOptions& options);

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
