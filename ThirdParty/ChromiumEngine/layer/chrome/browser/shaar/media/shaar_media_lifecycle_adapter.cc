// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/media/shaar_media.h"

// The lifecycle registry supplies the only engine/runtime context. The media
// handlers never reach into lifecycle globals or retain borrowed ABI handles.
extern "C" void shaar_media_register(ShaarModuleRegistry* registry) {
  if (registry) {
    shaar::media::BindRuntimeServices();
    registry->Register(SHAAR_OP_MEDIA_GET_STATE, SHAAR_OP_MEDIA_CAPTURE_REPLY,
                       &HandleMediaOperation);
    static const ShaarModuleRegistry::Handler handlers =
        &HandleMediaOperation;
    registry->RegisterModule(SHAAR_MODULE_MEDIA, &handlers);
  }
}
