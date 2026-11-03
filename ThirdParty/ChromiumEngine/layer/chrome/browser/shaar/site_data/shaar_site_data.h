// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_SITE_DATA_SHAAR_SITE_DATA_H_
#define CHROME_BROWSER_SHAAR_SITE_DATA_SHAAR_SITE_DATA_H_

#include <string_view>
#include <string>

#include "chrome/browser/shaar/engine/shaar_engine_context.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"

namespace shaar {
struct SiteDataModuleHandlers {
  ShaarModuleRegistry::Handler submit = nullptr;
};
}

shaar_error_code HandleSiteDataOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id, shaar_reply_fn,
    void*, shaar_error*);
extern "C" void shaar_site_data_register(ShaarModuleRegistry* registry);
bool IsValidSiteDataOriginForTesting(std::string_view origin);
namespace shaar::site_data {
bool IsPrivateSessionCurrent(
    ShaarEngineContext* context, shaar_engine* engine,
    shaar_private_session* session, Profile* expected_profile,
    std::string_view expected_profile_id, std::string_view expected_session_id);
shaar_error_code ClearCompletionStatus(
    ShaarEngineContext* context, shaar_engine* engine,
    shaar_private_session* session, Profile* expected_profile,
    std::string_view expected_profile_id, std::string_view expected_session_id,
    bool remover_failed);
}  // namespace shaar::site_data

#endif  // CHROME_BROWSER_SHAAR_SITE_DATA_SHAAR_SITE_DATA_H_
