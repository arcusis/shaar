// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/extensions/shaar_extensions.h"

extern "C" void shaar_extensions_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  static const shaar::ExtensionsModuleHandlers handlers{
      .submit = &HandleExtensionsOperation};
  registry->RegisterModule(SHAAR_MODULE_EXTENSIONS, &handlers);
  registry->Register(SHAAR_OP_EXTENSION_LIST, SHAAR_OP_EXTENSION_MANAGER_OPEN,
                     &HandleExtensionsOperation);
  registry->Register(SHAAR_OP_PROBE_FRAMEWORK_DEVTOOLS,
                     SHAAR_OP_PROBE_FRAMEWORK_DEVTOOLS,
                     &HandleExtensionsOperation);
}
