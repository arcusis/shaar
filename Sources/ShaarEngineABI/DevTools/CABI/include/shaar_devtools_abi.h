// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef SHAAR_DEVTOOLS_ABI_SHIM_H_
#define SHAAR_DEVTOOLS_ABI_SHIM_H_

#include "../../../../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

void* shaar_devtools_frontend_view_invoke(
    const void* view_symbol, shaar_engine* engine, const shaar_scope* scope,
    shaar_window* window, shaar_tab* tab, shaar_bytes profile_id,
    shaar_bytes session_id, shaar_bytes window_id, shaar_bytes tab_id);
uint32_t shaar_devtools_frontend_bounds_invoke(
    const void* bounds_symbol, shaar_engine* engine, const shaar_scope* scope,
    shaar_window* window, shaar_tab* tab, shaar_bytes profile_id,
    shaar_bytes session_id, shaar_bytes window_id, shaar_bytes tab_id,
    int width, int height);

#ifdef __cplusplus
}
#endif

#endif  // SHAAR_DEVTOOLS_ABI_SHIM_H_
