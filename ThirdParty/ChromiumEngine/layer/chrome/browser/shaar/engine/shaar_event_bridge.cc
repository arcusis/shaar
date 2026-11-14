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

bool RequestAppWindow(shaar_engine* engine,
                      std::string_view profile_id,
                      std::string_view request_type,
                      bool user_gesture,
                      std::string* window_id) {
  if (!engine || !engine->on_window_request || !window_id ||
      profile_id.empty() || request_type.empty() || !user_gesture ||
      !pthread_main_np())
    return false;
  char requested_id[128] = {};
  size_t requested_size = 0;
  const shaar_error_code result = engine->on_window_request(
      engine->window_request_context,
      {profile_id.data(), profile_id.size()},
      {request_type.data(), request_type.size()}, 1, requested_id,
      sizeof(requested_id), &requested_size);
  if (result != SHAAR_OK || requested_size == 0 ||
      requested_size > sizeof(requested_id) ||
      std::string_view(requested_id, requested_size).find('\0') !=
          std::string_view::npos)
    return false;
  window_id->assign(requested_id, requested_size);
  return true;
}

shaar_error_code EmitEvent(shaar_engine* engine,
                           shaar_event_kind kind,
                           shaar_bytes profile_id,
                           shaar_bytes session_id,
                           shaar_bytes window_id,
                           shaar_bytes tab_id,
                           shaar_bytes payload_json) {
  if (!engine || !engine->on_event || !pthread_main_np())
    return SHAAR_NOT_READY;
  if (kind < SHAAR_EVENT_ENGINE || kind > SHAAR_EVENT_ZOOM ||
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
