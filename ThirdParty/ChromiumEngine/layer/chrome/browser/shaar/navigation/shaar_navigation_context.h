// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_NAVIGATION_SHAAR_NAVIGATION_CONTEXT_H_
#define CHROME_BROWSER_SHAAR_NAVIGATION_SHAAR_NAVIGATION_CONTEXT_H_

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/windows_tabs/shaar_windows_tabs_context.h"

extern "C" void shaar_navigation_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_NAVIGATION_SHAAR_NAVIGATION_CONTEXT_H_
