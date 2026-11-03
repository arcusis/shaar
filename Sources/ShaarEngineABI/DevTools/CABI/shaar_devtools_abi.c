// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "shaar_devtools_abi.h"

typedef void* (*shaar_devtools_frontend_view_fn)(
    shaar_engine*, shaar_scope, shaar_window*, shaar_tab*, shaar_bytes,
    shaar_bytes, shaar_bytes, shaar_bytes);
typedef shaar_error_code (*shaar_devtools_frontend_bounds_fn)(
    shaar_engine*, shaar_scope, shaar_window*, shaar_tab*, shaar_bytes,
    shaar_bytes, shaar_bytes, shaar_bytes, int, int);

void* shaar_devtools_frontend_view_invoke(
    const void* view_symbol,
    shaar_engine* engine,
    const shaar_scope* scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_bytes profile_id,
    shaar_bytes session_id,
    shaar_bytes window_id,
    shaar_bytes tab_id) {
  if (!view_symbol || !scope)
    return NULL;
  shaar_devtools_frontend_view_fn view =
      (shaar_devtools_frontend_view_fn)view_symbol;
  return view(engine, *scope, window, tab, profile_id, session_id, window_id,
              tab_id);
}

uint32_t shaar_devtools_frontend_bounds_invoke(
    const void* bounds_symbol,
    shaar_engine* engine,
    const shaar_scope* scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_bytes profile_id,
    shaar_bytes session_id,
    shaar_bytes window_id,
    shaar_bytes tab_id,
    int width,
    int height) {
  if (!bounds_symbol || !scope)
    return SHAAR_INVALID_ARGUMENT;
  shaar_devtools_frontend_bounds_fn bounds =
      (shaar_devtools_frontend_bounds_fn)bounds_symbol;
  return (uint32_t)bounds(engine, *scope, window, tab, profile_id, session_id,
                          window_id, tab_id, width, height);
}
