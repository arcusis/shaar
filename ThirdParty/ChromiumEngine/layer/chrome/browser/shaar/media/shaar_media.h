// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_MEDIA_SHAAR_MEDIA_H_
#define CHROME_BROWSER_SHAAR_MEDIA_SHAAR_MEDIA_H_

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "services/media_session/public/mojom/media_session.mojom.h"

namespace content {
class WebContents;
}

namespace shaar::media {

// Pure helpers used by the handler and its focused unit tests.
bool IsValidControl(uint32_t command, double value, bool has_value);
bool MapSessionAction(uint32_t command,
                     media_session::mojom::MediaSessionAction* action);

}  // namespace shaar::media

shaar_error_code HandleMediaOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id, shaar_reply_fn,
    void*, shaar_error*);
extern "C" void shaar_media_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_MEDIA_SHAAR_MEDIA_H_
