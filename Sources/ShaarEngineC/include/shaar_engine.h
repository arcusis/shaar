// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Import the canonical engine ABI declaration from the pinned Chromium source tree.
#include "../../../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h"

// Keep the Swift operation contract test tied to values compiled from the C ABI.
#ifdef __cplusplus
extern "C" {
#endif
const uint32_t *shaar_operation_contract_values(size_t *count);
#ifdef __cplusplus
}
#endif
