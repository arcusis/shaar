// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_FIND_SHAAR_FIND_H_
#define CHROME_BROWSER_SHAAR_FIND_SHAAR_FIND_H_

#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"

shaar_error_code HandleFindOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id,
    shaar_reply_fn, void*, shaar_error*);

extern "C" void shaar_find_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_FIND_SHAAR_FIND_H_
