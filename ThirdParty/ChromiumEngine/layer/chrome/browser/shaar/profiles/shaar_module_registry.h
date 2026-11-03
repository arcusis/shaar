// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PROFILES_SHAAR_MODULE_REGISTRY_H_
#define CHROME_BROWSER_SHAAR_PROFILES_SHAAR_MODULE_REGISTRY_H_

#include "chrome/browser/shaar/public/shaar_engine.h"

namespace shaar {

// Temporary module-facing contract. Replace with lifecycle's shared declaration
// when that module lands. The handler returns immediate acceptance/error and
// posts exactly one reply for every accepted request.
class ShaarModuleRegistry {
 public:
  using Handler = shaar_error_code (*)(
      shaar_engine*, shaar_scope, shaar_window*, shaar_tab*, shaar_operation,
      shaar_bytes, shaar_request_id, shaar_reply_fn, void*, shaar_error*);
  virtual ~ShaarModuleRegistry() = default;
  virtual void Register(shaar_operation operation, Handler handler) = 0;
};

}  // namespace shaar

void shaar_profiles_register(shaar::ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_PROFILES_SHAAR_MODULE_REGISTRY_H_
