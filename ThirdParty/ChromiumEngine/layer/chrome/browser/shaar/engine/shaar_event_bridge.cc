// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_event_bridge.h"

#include <limits>
#include <pthread.h>

namespace {

bool ValidBytes(shaar_bytes bytes) {
  return bytes.size == 0 || bytes.data != nullptr;
}

}  // namespace

namespace shaar {

shaar_error_code EmitEvent(shaar_engine* engine,
                           shaar_event_kind kind,
                           shaar_bytes profile_id,
                           shaar_bytes session_id,
                           shaar_bytes window_id,
                           shaar_bytes tab_id,
                           shaar_bytes payload_json) {
  if (!engine || !engine->on_event || !pthread_main_np())
    return SHAAR_NOT_READY;
  if (kind < SHAAR_EVENT_ENGINE || kind > SHAAR_EVENT_JAVASCRIPT_DIALOG ||
      (kind != SHAAR_EVENT_ENGINE && profile_id.size == 0) ||
      (kind == SHAAR_EVENT_PRIVATE_SESSION && session_id.size == 0) ||
      !ValidBytes(profile_id) || !ValidBytes(session_id) ||
      !ValidBytes(window_id) || !ValidBytes(tab_id) ||
      !ValidBytes(payload_json))
    return SHAAR_INVALID_ARGUMENT;
  if (engine->emitting ||
      engine->next_sequence == std::numeric_limits<uint64_t>::max())
    return SHAAR_CONFLICT;

  shaar_event event = {};
  event.size = sizeof(event);
  event.sequence = ++engine->next_sequence;
  event.kind = kind;
  event.profile_id = profile_id;
  event.session_id = session_id;
  event.window_id = window_id;
  event.tab_id = tab_id;
  event.payload_json = payload_json;
  engine->emitting = true;
  engine->on_event(engine->event_context, &event);
  const bool release_requested = engine->release_requested;
  engine->emitting = false;
  if (release_requested)
    RetireEngine(engine);
  return SHAAR_OK;
}

}  // namespace shaar
