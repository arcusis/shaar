// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_HANDLERS_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_HANDLERS_H_

#include "chrome/browser/shaar/windows-tabs/shaar_module_registry.h"

namespace shaar::windows_tabs {

shaar_error_code HandleWindowBindProfile(const ModuleCall*, shaar_error*);
shaar_error_code HandleWindowSetActiveProfile(const ModuleCall*, shaar_error*);
shaar_error_code HandleWindowActivateTab(const ModuleCall*, shaar_error*);
shaar_error_code HandleWindowPlaceTabs(const ModuleCall*, shaar_error*);
shaar_error_code HandleWindowRequestResolve(const ModuleCall*, shaar_error*);
shaar_error_code HandleTabMove(const ModuleCall*, shaar_error*);
shaar_error_code HandleTabActivationResolve(const ModuleCall*, shaar_error*);
shaar_error_code HandleWindowSetBounds(const ModuleCall*, shaar_error*);
shaar_error_code HandleModuleOperation(const ModuleCall*, shaar_error*);

}  // namespace shaar::windows_tabs

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_WINDOWS_TABS_HANDLERS_H_
