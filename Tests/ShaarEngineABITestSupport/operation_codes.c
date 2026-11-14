// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "operation_codes.h"
#include "../../Sources/ShaarEngineC/include/shaar_engine.h"

void shaar_test_get_operation_codes(shaar_test_operation_codes *codes) {
  if (!codes) return;
  *codes = (shaar_test_operation_codes){
      .tab_navigate = SHAAR_OP_TAB_NAVIGATE,
      .tab_go = SHAAR_OP_TAB_GO,
      .tab_reload = SHAAR_OP_TAB_RELOAD,
      .tab_stop = SHAAR_OP_TAB_STOP,
      .download_list = SHAAR_OP_DOWNLOAD_LIST,
      .download_control = SHAAR_OP_DOWNLOAD_CONTROL,
      .download_directory = SHAAR_OP_DOWNLOAD_DIRECTORY,
      .bookmark_tree = SHAAR_OP_BOOKMARK_TREE,
      .bookmark_apply = SHAAR_OP_BOOKMARK_APPLY,
      .bookmark_watch = SHAAR_OP_BOOKMARK_WATCH,
      .history_query = SHAAR_OP_HISTORY_QUERY,
      .history_insert = SHAAR_OP_HISTORY_INSERT,
      .history_delete = SHAAR_OP_HISTORY_DELETE,
      .history_watch = SHAAR_OP_HISTORY_WATCH,
      .history_unwatch = SHAAR_OP_HISTORY_UNWATCH,
      .site_settings_get = SHAAR_OP_SITE_SETTINGS_GET,
      .site_settings_set = SHAAR_OP_SITE_SETTINGS_SET,
      .site_settings_reset = SHAAR_OP_SITE_SETTINGS_RESET,
      .extension_list = SHAAR_OP_EXTENSION_LIST,
      .extension_manage = SHAAR_OP_EXTENSION_MANAGE,
      .extension_action = SHAAR_OP_EXTENSION_ACTION,
      .extension_install_decision = SHAAR_OP_EXTENSION_INSTALL_DECISION,
      .extension_popup_close = SHAAR_OP_EXTENSION_POPUP_CLOSE,
      .tab_find = SHAAR_OP_TAB_FIND,
      .tab_stop_find = SHAAR_OP_TAB_STOP_FIND,
      .devtools_call = SHAAR_OP_DEVTOOLS_CALL,
      .devtools_panel_open = SHAAR_OP_DEVTOOLS_PANEL_OPEN,
      .devtools_panel_close = SHAAR_OP_DEVTOOLS_PANEL_CLOSE,
      .devtools_panel_screencast = SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST,
      .media_get_state = SHAAR_OP_MEDIA_GET_STATE,
      .media_control = SHAAR_OP_MEDIA_CONTROL,
      .media_capture_reply = SHAAR_OP_MEDIA_CAPTURE_REPLY,
      .storage_keychain_identity = SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY,
  };
}
