// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef SHAAR_STORAGE_KEYCHAIN_ABI_SHIM_H_
#define SHAAR_STORAGE_KEYCHAIN_ABI_SHIM_H_

#include "../../../../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

uint32_t shaar_storage_keychain_submit_invoke(
    const void* submit_symbol,
    shaar_engine* engine,
    const shaar_scope* scope,
    uint32_t operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* immediate_error);

#ifdef __cplusplus
}
#endif

#endif  // SHAAR_STORAGE_KEYCHAIN_ABI_SHIM_H_
