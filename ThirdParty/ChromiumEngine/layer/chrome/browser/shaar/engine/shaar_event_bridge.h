// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_ENGINE_SHAAR_EVENT_BRIDGE_H_
#define CHROME_BROWSER_SHAAR_ENGINE_SHAAR_EVENT_BRIDGE_H_

#include <stdint.h>

#include <string>  // Shaar profiles module stores the configured data root.

#include "chrome/browser/shaar/public/shaar_engine.h"

struct shaar_engine {
  // BEGIN Shaar profiles module state.
  std::string data_root;
  // END Shaar profiles module state.
  shaar_event_fn on_event = nullptr;
  void* event_context = nullptr;
  uint64_t next_sequence = 0;
  bool emitting = false;
  bool release_requested = false;
};

namespace shaar {

// Called by future Chromium module owners on the UI thread after mutation.
// All slices are borrowed until the callback returns. No second sink exists.
shaar_error_code EmitEvent(shaar_engine* engine,
                           shaar_event_kind kind,
                           shaar_bytes profile_id,
                           shaar_bytes session_id,
                           shaar_bytes window_id,
                           shaar_bytes tab_id,
                           shaar_bytes payload_json);

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_ENGINE_SHAAR_EVENT_BRIDGE_H_
