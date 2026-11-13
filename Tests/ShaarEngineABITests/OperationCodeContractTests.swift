// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import Testing

@testable import ShaarEngineABI

@Test func swiftOperationIDsMatchThePublicCABI() {
  let mappings = [
    ShaarNavigationOperation.navigate.rawValue == UInt32(SHAAR_OP_TAB_NAVIGATE.rawValue),
    ShaarNavigationOperation.go.rawValue == UInt32(SHAAR_OP_TAB_GO.rawValue),
    ShaarNavigationOperation.reload.rawValue == UInt32(SHAAR_OP_TAB_RELOAD.rawValue),
    ShaarNavigationOperation.stop.rawValue == UInt32(SHAAR_OP_TAB_STOP.rawValue),
    ShaarDownloadsAdapter.listOperation == UInt32(SHAAR_OP_DOWNLOAD_LIST.rawValue),
    ShaarDownloadsAdapter.controlOperation == UInt32(SHAAR_OP_DOWNLOAD_CONTROL.rawValue),
    ShaarDownloadsAdapter.directoryOperation == UInt32(SHAAR_OP_DOWNLOAD_DIRECTORY.rawValue),
    ShaarBookmarkOperation.tree.rawValue == UInt32(SHAAR_OP_BOOKMARK_TREE.rawValue),
    ShaarBookmarkOperation.apply.rawValue == UInt32(SHAAR_OP_BOOKMARK_APPLY.rawValue),
    ShaarBookmarkOperation.watch.rawValue == UInt32(SHAAR_OP_BOOKMARK_WATCH.rawValue),
    ShaarHistoryOperation.query.rawValue == UInt32(SHAAR_OP_HISTORY_QUERY.rawValue),
    ShaarHistoryOperation.insert.rawValue == UInt32(SHAAR_OP_HISTORY_INSERT.rawValue),
    ShaarHistoryOperation.delete.rawValue == UInt32(SHAAR_OP_HISTORY_DELETE.rawValue),
    ShaarHistoryOperation.watch.rawValue == UInt32(SHAAR_OP_HISTORY_WATCH.rawValue),
    ShaarHistoryOperation.unwatch.rawValue == UInt32(SHAAR_OP_HISTORY_UNWATCH.rawValue),
    ShaarSiteDataOperation.settingsGet.rawValue == UInt32(SHAAR_OP_SITE_SETTINGS_GET.rawValue),
    ShaarSiteDataOperation.settingsSet.rawValue == UInt32(SHAAR_OP_SITE_SETTINGS_SET.rawValue),
    ShaarSiteDataOperation.settingsReset.rawValue == UInt32(SHAAR_OP_SITE_SETTINGS_RESET.rawValue),
    ShaarExtensionsOperation.list.rawValue == UInt32(SHAAR_OP_EXTENSION_LIST.rawValue),
    ShaarExtensionsOperation.manage.rawValue == UInt32(SHAAR_OP_EXTENSION_MANAGE.rawValue),
    ShaarExtensionsOperation.action.rawValue == UInt32(SHAAR_OP_EXTENSION_ACTION.rawValue),
    ShaarExtensionsOperation.installDecision.rawValue
      == UInt32(SHAAR_OP_EXTENSION_INSTALL_DECISION.rawValue),
    ShaarExtensionsOperation.popupClose.rawValue == UInt32(SHAAR_OP_EXTENSION_POPUP_CLOSE.rawValue),
    ShaarFindOperation.find.rawValue == UInt32(SHAAR_OP_TAB_FIND.rawValue),
    ShaarFindOperation.stop.rawValue == UInt32(SHAAR_OP_TAB_STOP_FIND.rawValue),
    ShaarDevToolsOperation.call.rawValue == UInt32(SHAAR_OP_DEVTOOLS_CALL.rawValue),
    ShaarDevToolsOperation.panelOpen.rawValue == UInt32(SHAAR_OP_DEVTOOLS_PANEL_OPEN.rawValue),
    ShaarDevToolsOperation.panelClose.rawValue == UInt32(SHAAR_OP_DEVTOOLS_PANEL_CLOSE.rawValue),
    ShaarDevToolsOperation.panelScreencast.rawValue
      == UInt32(SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST.rawValue),
    ShaarMediaOperation.getState.rawValue == UInt32(SHAAR_OP_MEDIA_GET_STATE.rawValue),
    ShaarMediaOperation.control.rawValue == UInt32(SHAAR_OP_MEDIA_CONTROL.rawValue),
    ShaarMediaOperation.captureReply.rawValue == UInt32(SHAAR_OP_MEDIA_CAPTURE_REPLY.rawValue),
    ShaarStorageKeychainAdapter.identityOperation
      == UInt32(SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY.rawValue),
  ]
  #expect(mappings.allSatisfy { $0 })
}
