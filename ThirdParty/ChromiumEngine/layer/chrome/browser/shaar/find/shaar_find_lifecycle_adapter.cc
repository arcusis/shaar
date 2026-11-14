// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/find/shaar_find.h"

extern "C" void shaar_find_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_TAB_FIND, SHAAR_OP_TAB_STOP_FIND,
                     &HandleFindOperation);
  registry->Register(SHAAR_OP_TAB_ZOOM, SHAAR_OP_TAB_ZOOM,
                     &HandlePageZoomOperation);
}
