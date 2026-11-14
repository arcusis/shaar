// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "shaar_storage_keychain_abi.h"

typedef shaar_error_code (*shaar_submit_fn)(
    shaar_engine*, shaar_scope, shaar_window*, shaar_tab*, shaar_operation,
    shaar_bytes, shaar_request_id, shaar_reply_fn, void*, shaar_error*);

uint32_t shaar_storage_keychain_submit_invoke(
    const void* submit_symbol,
    shaar_engine* engine,
    const shaar_scope* scope,
    uint32_t operation,
    shaar_bytes args_json,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* immediate_error) {
  if (!submit_symbol || !engine || !scope || scope->size < sizeof(*scope) ||
      !scope->profile || scope->private_session || !reply || !immediate_error ||
      immediate_error->size < sizeof(*immediate_error))
    return SHAAR_INVALID_ARGUMENT;
  shaar_submit_fn submit = (shaar_submit_fn)submit_symbol;
  return (uint32_t)submit(engine, *scope, NULL, NULL, (shaar_operation)operation,
                          args_json, request_id, reply, reply_context,
                          immediate_error);
}
