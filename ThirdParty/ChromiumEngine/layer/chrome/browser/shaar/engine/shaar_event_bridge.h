// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_ENGINE_SHAAR_EVENT_BRIDGE_H_
#define CHROME_BROWSER_SHAAR_ENGINE_SHAAR_EVENT_BRIDGE_H_

#include <stdint.h>

#include <string>
#include <string_view>

#include "chrome/browser/shaar/public/shaar_engine.h"

struct shaar_engine {
  shaar_event_fn on_event = nullptr;
  void* event_context = nullptr;
  shaar_window_request_fn on_window_request = nullptr;
  void* window_request_context = nullptr;
  std::string data_root;
  std::string locale;
  uint64_t next_sequence = 0;
  bool emitting = false;
  bool release_requested = false;
  bool run_active = false;
};

namespace shaar {

// Opaque ABI handles are checked by address before any field is read. Retired
// allocations remain reserved so a stale address cannot alias a new engine.
bool EngineIsLive(const shaar_engine* engine);
void RetireEngine(shaar_engine* engine);

// Called by future Chromium module owners on the UI thread after mutation.
// All slices are borrowed until the callback returns. No second sink exists.
shaar_error_code EmitEvent(shaar_engine* engine,
                           shaar_event_kind kind,
                           shaar_bytes profile_id,
                           shaar_bytes session_id,
                           shaar_bytes window_id,
                           shaar_bytes tab_id,
                           shaar_bytes payload_json);
bool RequestAppWindow(shaar_engine* engine,
                      std::string_view profile_id,
                      std::string_view request_type,
                      bool user_gesture,
                      std::string* window_id);

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_ENGINE_SHAAR_EVENT_BRIDGE_H_
