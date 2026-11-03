// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/storage_keychain/shaar_storage_keychain.h"

extern "C" void shaar_storage_keychain_register(
    ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  registry->Register(SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY,
                     SHAAR_OP_STORAGE_KEYCHAIN_IDENTITY,
                     &shaar::storage_keychain::HandleIdentityStatus);
  static const shaar::storage_keychain::StorageKeychainModuleHandlers handlers{
      .identity = &shaar::storage_keychain::CurrentSafeStorageIdentity};
  registry->RegisterModule(SHAAR_MODULE_STORAGE_KEYCHAIN, &handlers);
}
