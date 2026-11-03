// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PROFILES_SHAAR_PROFILES_H_
#define CHROME_BROWSER_SHAAR_PROFILES_SHAAR_PROFILES_H_

#include <string>

#include "chrome/browser/shaar/public/shaar_engine.h"

namespace shaar::profiles {

// Validates the canonical ID and returns its only permitted relative path.
bool CanonicalDirectory(shaar_bytes profile_id, std::string* directory);

}  // namespace shaar::profiles

struct ShaarModuleRegistry;
extern "C" void shaar_profiles_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_PROFILES_SHAAR_PROFILES_H_
