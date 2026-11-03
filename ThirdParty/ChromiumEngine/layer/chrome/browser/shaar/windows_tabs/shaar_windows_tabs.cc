// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs.h"

#include <algorithm>
#include <unordered_map>
#include <unordered_set>

#include "chrome/browser/ui/tabs/tab_strip_model.h"

namespace shaar::windows_tabs {

bool ValidatePlacement(const std::vector<std::string>& requested_ids,
                       const std::vector<std::string>& current_ids,
                       const std::vector<std::string>& pinned_ids) {
  const std::unordered_set<std::string> current(current_ids.begin(),
                                                 current_ids.end());
  const std::unordered_set<std::string> requested(requested_ids.begin(),
                                                   requested_ids.end());
  const std::unordered_set<std::string> pinned(pinned_ids.begin(),
                                                pinned_ids.end());
  if (current.size() != current_ids.size() ||
      requested.size() != requested_ids.size() ||
      pinned.size() != pinned_ids.size() || requested != current)
    return false;
  bool encountered_unpinned = false;
  for (const auto& id : requested_ids) {
    if (pinned.contains(id)) {
      if (encountered_unpinned)
        return false;
    } else {
      encountered_unpinned = true;
    }
  }
  return std::all_of(pinned.begin(), pinned.end(),
                     [&current](const auto& id) { return current.contains(id); });
}

bool ApplyPlacement(TabStripModel* model,
                    const std::vector<std::string>& requested_ids,
                    const std::unordered_map<std::string,
                                             content::WebContents*>& current_tabs,
                    const std::vector<std::string>& pinned_ids) {
  std::vector<std::string> current_ids;
  current_ids.reserve(current_tabs.size());
  for (const auto& [id, contents] : current_tabs) {
    if (id.empty() || !contents)
      return false;
    current_ids.push_back(id);
  }
  if (!model || !ValidatePlacement(requested_ids, current_ids, pinned_ids) ||
      model->count() != static_cast<int>(current_tabs.size()))
    return false;

  // Pin state changes can relocate a tab. Apply them before resolving indices,
  // then locate each requested tab against the live model for each move.
  std::unordered_set<content::WebContents*> unique_contents;
  for (const auto& [id, contents] : current_tabs) {
    if (!unique_contents.insert(contents).second ||
        model->GetIndexOfWebContents(contents) < 0)
      return false;
  }
  const std::unordered_set<std::string> pinned(pinned_ids.begin(),
                                                pinned_ids.end());
  for (const auto& [id, contents] : current_tabs) {
    const int live_index = model->GetIndexOfWebContents(contents);
    if (live_index < 0 || model->IsTabPinned(live_index) == pinned.contains(id))
      continue;
    model->SetTabPinned(live_index, pinned.contains(id));
  }
  for (size_t target = 0; target < requested_ids.size(); ++target) {
    auto* contents = current_tabs.at(requested_ids[target]);
    const int from = model->GetIndexOfWebContents(contents);
    if (from >= 0 && from != static_cast<int>(target))
      model->MoveWebContentsAt(from, static_cast<int>(target), false);
  }
  return true;
}

}  // namespace shaar::windows_tabs
