// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_STORAGE_KEYCHAIN_SHAAR_STORAGE_KEYCHAIN_H_
#define CHROME_BROWSER_SHAAR_STORAGE_KEYCHAIN_SHAAR_STORAGE_KEYCHAIN_H_

#include <string>

#include "base/values.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace shaar::storage_keychain {

struct SafeStorageIdentity {
  std::string service_name;
  std::string account_name;
};

struct StorageKeychainModuleHandlers {
  SafeStorageIdentity (*identity)();
};

// Returns only Chromium's configured item identity. It never reads the
// keychain or returns key material.
SafeStorageIdentity CurrentSafeStorageIdentity();

// Status is intentionally non-secret and profile-scoped. The module confirms
// the engine identity; Chromium's OSCrypt migration remains responsible for
// copying an existing legacy secret without replacing it.
shaar_error_code HandleIdentityStatus(
    ShaarEngineContext* engine_context,
    shaar_engine* engine,
    shaar_scope scope,
    shaar_window* window,
    shaar_tab* tab,
    shaar_operation operation,
    shaar_bytes args,
    shaar_request_id request_id,
    shaar_reply_fn reply,
    void* reply_context,
    shaar_error* error);

}  // namespace shaar::storage_keychain

extern "C" void shaar_storage_keychain_register(
    ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_STORAGE_KEYCHAIN_SHAAR_STORAGE_KEYCHAIN_H_
