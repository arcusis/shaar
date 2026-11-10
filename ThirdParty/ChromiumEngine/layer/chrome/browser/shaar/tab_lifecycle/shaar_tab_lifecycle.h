// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_TAB_LIFECYCLE_SHAAR_TAB_LIFECYCLE_H_
#define CHROME_BROWSER_SHAAR_TAB_LIFECYCLE_SHAAR_TAB_LIFECYCLE_H_

#include <string_view>

#include "chrome/browser/shaar/engine/shaar_module_registry.h"

namespace content {
class WebContents;
}

namespace shaar::tab_lifecycle {

// Posted after Chromium finishes a discard, including one Chrome started
// itself. The WebContents pointer is only used while this call is on the
// stack; the event is delivered on a later UI-thread task.
void NoteDiscarded(shaar_engine* engine,
                   std::string_view profile_id,
                   std::string_view session_id,
                   std::string_view window_id,
                   std::string_view tab_id,
                   content::WebContents* contents);

}  // namespace shaar::tab_lifecycle

shaar_error_code HandleTabLifecycleOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id, shaar_reply_fn,
    void*, shaar_error*);
extern "C" void shaar_tab_lifecycle_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_TAB_LIFECYCLE_SHAAR_TAB_LIFECYCLE_H_
