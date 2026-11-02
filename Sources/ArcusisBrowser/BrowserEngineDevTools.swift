// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation

extension BrowserEngine {
  @discardableResult
  func showDeveloperTools(for target: SiteControlTarget) -> Bool {
    guard siteControlTarget == target else { return false }
    let shown = runtime.showDevTools(forTabID: target.tabID.uuidString)
    developerModels[target.tabID]?.update(target: target)
    return shown
  }

  func toggleDeveloperTools() {
    guard let target = siteControlTarget else { return }
    let identity = target.tabID.uuidString
    if runtime.devToolsView(forTabID: identity) != nil {
      runtime.closeDevTools(forTabID: identity)
    } else {
      runtime.showDevTools(forTabID: identity)
    }
    developerModels[target.tabID]?.update(target: target)
  }
}
