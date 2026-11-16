// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import Testing

@testable import ShaarEngineABI

@Test func swiftOperationIDsMatchThePublicCABI() {
  let swiftValues: [UInt32] = [
    ShaarNavigationOperation.navigate.rawValue,
    ShaarNavigationOperation.go.rawValue,
    ShaarNavigationOperation.reload.rawValue,
    ShaarNavigationOperation.stop.rawValue,
    ShaarDownloadsAdapter.listOperation,
    ShaarDownloadsAdapter.controlOperation,
    ShaarDownloadsAdapter.directoryOperation,
    ShaarBookmarkOperation.tree.rawValue,
    ShaarBookmarkOperation.apply.rawValue,
    ShaarBookmarkOperation.watch.rawValue,
    ShaarHistoryOperation.query.rawValue,
    ShaarHistoryOperation.insert.rawValue,
    ShaarHistoryOperation.delete.rawValue,
    ShaarHistoryOperation.watch.rawValue,
    ShaarHistoryOperation.unwatch.rawValue,
    ShaarSiteDataOperation.settingsGet.rawValue,
    ShaarSiteDataOperation.settingsSet.rawValue,
    ShaarSiteDataOperation.settingsReset.rawValue,
    ShaarExtensionsOperation.list.rawValue,
    ShaarExtensionsOperation.manage.rawValue,
    ShaarExtensionsOperation.action.rawValue,
    ShaarExtensionsOperation.installDecision.rawValue,
    ShaarExtensionsOperation.popupClose.rawValue,
    ShaarFindOperation.find.rawValue,
    ShaarFindOperation.stop.rawValue,
    ShaarDevToolsOperation.call.rawValue,
    ShaarDevToolsOperation.panelOpen.rawValue,
    ShaarDevToolsOperation.panelClose.rawValue,
    ShaarDevToolsOperation.panelScreencast.rawValue,
    ShaarMediaOperation.getState.rawValue,
    ShaarMediaOperation.control.rawValue,
    ShaarMediaOperation.captureReply.rawValue,
    ShaarStorageKeychainAdapter.identityOperation,
  ]
  var count = 0
  let cValues = shaar_operation_contract_values(&count)
  #expect(count == swiftValues.count)
  for (index, swiftValue) in swiftValues.enumerated() {
    #expect(swiftValue == cValues?[index])
  }
}
