// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_

#include <string>
#include <unordered_map>
#include <vector>

class TabStripModel;
namespace content {
class WebContents;
}

namespace shaar::windows_tabs {

// Validates a complete caller order against the IDs currently bound to this
// strip. The caller must perform this check before mutating Chromium state.
bool ValidatePlacement(const std::vector<std::string>& requested_ids,
                       const std::vector<std::string>& current_ids,
                       const std::vector<std::string>& pinned_ids);

// Applies a previously validated complete order using the Chromium 155
// TabStripModel API. Tab IDs are caller-owned identities, never Chromium IDs.
bool ApplyPlacement(TabStripModel* model,
                    const std::vector<std::string>& requested_ids,
                    const std::unordered_map<std::string,
                                             content::WebContents*>& current_tabs,
                    const std::vector<std::string>& pinned_ids);

}  // namespace shaar::windows_tabs

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_H_
