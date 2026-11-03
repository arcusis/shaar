// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_DOWNLOADS_SHAAR_MODULE_REGISTRY_H_
#define CHROME_BROWSER_SHAAR_DOWNLOADS_SHAAR_MODULE_REGISTRY_H_

#include <string>

#include "chrome/browser/shaar/public/shaar_engine.h"

namespace shaar {

// Temporary declaration until lifecycle's shared registry is merged. A module
// context is owned by the exact profile/session scope resolved by the engine.
using ModuleHandler = bool (*)(void* module_context,
                               shaar_operation operation,
                               const std::string& arguments_json,
                               std::string* payload_json,
                               shaar_error_code* error_code);

class ShaarModuleRegistry {
 public:
  virtual ~ShaarModuleRegistry() = default;
  virtual void Register(shaar_operation operation, ModuleHandler handler) = 0;
};

}  // namespace shaar

#endif  // CHROME_BROWSER_SHAAR_DOWNLOADS_SHAAR_MODULE_REGISTRY_H_
