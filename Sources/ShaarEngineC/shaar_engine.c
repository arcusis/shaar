// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "shaar_engine.h"

const uint32_t *shaar_operation_contract_values(size_t *count) {
  static const uint32_t values[] = {
      SHAAR_OP_TAB_NAVIGATE,
      SHAAR_OP_TAB_GO,
      SHAAR_OP_TAB_RELOAD,
      SHAAR_OP_TAB_STOP,
      SHAAR_OP_DOWNLOAD_LIST,
      SHAAR_OP_DOWNLOAD_CONTROL,
      SHAAR_OP_DOWNLOAD_DIRECTORY,
      SHAAR_OP_BOOKMARK_TREE,
      SHAAR_OP_BOOKMARK_APPLY,
      SHAAR_OP_BOOKMARK_WATCH,
      SHAAR_OP_HISTORY_QUERY,
      SHAAR_OP_HISTORY_INSERT,
      SHAAR_OP_HISTORY_DELETE,
      SHAAR_OP_HISTORY_WATCH,
      SHAAR_OP_HISTORY_UNWATCH,
      SHAAR_OP_SITE_SETTINGS_GET,
      SHAAR_OP_SITE_SETTINGS_SET,
      SHAAR_OP_SITE_SETTINGS_RESET,
      SHAAR_OP_EXTENSION_LIST,
      SHAAR_OP_EXTENSION_MANAGE,
      SHAAR_OP_EXTENSION_ACTION,
      SHAAR_OP_EXTENSION_INSTALL_DECISION,
      SHAAR_OP_EXTENSION_POPUP_CLOSE,
      SHAAR_OP_TAB_FIND,
      SHAAR_OP_TAB_STOP_FIND,
      SHAAR_OP_DEVTOOLS_CALL,
      SHAAR_OP_DEVTOOLS_PANEL_OPEN,
      SHAAR_OP_DEVTOOLS_PANEL_CLOSE,
      SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST,
      SHAAR_OP_MEDIA_GET_STATE,
      SHAAR_OP_MEDIA_CONTROL,
      SHAAR_OP_MEDIA_CAPTURE_REPLY,
      SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY,
  };
  *count = sizeof(values) / sizeof(values[0]);
  return values;
}
