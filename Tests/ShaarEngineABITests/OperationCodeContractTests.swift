// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ShaarEngineC
import ShaarEngineABITestSupport
import Testing

@testable import ShaarEngineABI

@Test func swiftOperationIDsMatchThePublicCABI() {
  var c = shaar_test_operation_codes()
  shaar_test_get_operation_codes(&c)
  let mappings = [
    ShaarNavigationOperation.navigate.rawValue == c.tab_navigate,
    ShaarNavigationOperation.go.rawValue == c.tab_go,
    ShaarNavigationOperation.reload.rawValue == c.tab_reload,
    ShaarNavigationOperation.stop.rawValue == c.tab_stop,
    ShaarDownloadsAdapter.listOperation == c.download_list,
    ShaarDownloadsAdapter.controlOperation == c.download_control,
    ShaarDownloadsAdapter.directoryOperation == c.download_directory,
    ShaarBookmarkOperation.tree.rawValue == c.bookmark_tree,
    ShaarBookmarkOperation.apply.rawValue == c.bookmark_apply,
    ShaarBookmarkOperation.watch.rawValue == c.bookmark_watch,
    ShaarHistoryOperation.query.rawValue == c.history_query,
    ShaarHistoryOperation.insert.rawValue == c.history_insert,
    ShaarHistoryOperation.delete.rawValue == c.history_delete,
    ShaarHistoryOperation.watch.rawValue == c.history_watch,
    ShaarHistoryOperation.unwatch.rawValue == c.history_unwatch,
    ShaarSiteDataOperation.settingsGet.rawValue == c.site_settings_get,
    ShaarSiteDataOperation.settingsSet.rawValue == c.site_settings_set,
    ShaarSiteDataOperation.settingsReset.rawValue == c.site_settings_reset,
    ShaarExtensionsOperation.list.rawValue == c.extension_list,
    ShaarExtensionsOperation.manage.rawValue == c.extension_manage,
    ShaarExtensionsOperation.action.rawValue == c.extension_action,
    ShaarExtensionsOperation.installDecision.rawValue
      == c.extension_install_decision,
    ShaarExtensionsOperation.popupClose.rawValue == c.extension_popup_close,
    ShaarFindOperation.find.rawValue == c.tab_find,
    ShaarFindOperation.stop.rawValue == c.tab_stop_find,
    ShaarDevToolsOperation.call.rawValue == c.devtools_call,
    ShaarDevToolsOperation.panelOpen.rawValue == c.devtools_panel_open,
    ShaarDevToolsOperation.panelClose.rawValue == c.devtools_panel_close,
    ShaarDevToolsOperation.panelScreencast.rawValue
      == c.devtools_panel_screencast,
    ShaarMediaOperation.getState.rawValue == c.media_get_state,
    ShaarMediaOperation.control.rawValue == c.media_control,
    ShaarMediaOperation.captureReply.rawValue == c.media_capture_reply,
    ShaarStorageKeychainAdapter.identityOperation
      == c.storage_keychain_identity,
  ]
  #expect(mappings.allSatisfy { $0 })
}
