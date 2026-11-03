// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_H_
#define CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_H_

class ShaarModuleRegistry;

// Registers operations 600-604 with the engine's module handler table.
void shaar_history_register(ShaarModuleRegistry *registry);

#endif // CHROME_BROWSER_SHAAR_HISTORY_SHAAR_HISTORY_H_
