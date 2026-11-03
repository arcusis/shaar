// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/history/shaar_history.h"

extern "C" void shaar_history_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_HISTORY_QUERY, SHAAR_OP_HISTORY_QUERY,
                     &HandleHistoryOperation);
  registry->Register(SHAAR_OP_HISTORY_INSERT, SHAAR_OP_HISTORY_INSERT,
                     &HandleHistoryOperation);
  registry->Register(SHAAR_OP_HISTORY_DELETE, SHAAR_OP_HISTORY_DELETE,
                     &HandleHistoryOperation);
  registry->Register(SHAAR_OP_HISTORY_WATCH, SHAAR_OP_HISTORY_WATCH,
                     &HandleHistoryOperation);
  registry->Register(SHAAR_OP_HISTORY_UNWATCH, SHAAR_OP_HISTORY_UNWATCH,
                     &HandleHistoryOperation);
}
