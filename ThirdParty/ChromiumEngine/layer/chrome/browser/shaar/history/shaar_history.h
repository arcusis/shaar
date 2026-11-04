// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_H_
#define CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_H_

#include <string>

#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "components/history/core/browser/history_types.h"

shaar_error_code HandleHistoryOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id, shaar_reply_fn,
    void*, shaar_error*);
extern "C" void shaar_history_register(ShaarModuleRegistry* registry);

namespace shaar_history {
history::VisitSource VisitSourceForImport(const std::string& source);
// Detach observers while profile services are still alive during browser
// shutdown.
void StopObservingLifecycle(shaar_engine *engine);
bool HasWatchStateForTesting(shaar_engine *engine);
}

#endif // CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_H_
