// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_MODULE_H_
#define CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_MODULE_H_

#include "chrome/browser/shaar/engine/shaar_module_registry.h"
#include "chrome/browser/shaar/private_sessions/shaar_private_sessions.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace shaar {

struct PrivateSessionModuleHandlers {
  using Open = shaar_error_code (*)(void*, Profile*, const std::string&,
                                    const std::string&,
                                    PrivateSessionRegistry::Session**);
  using Close = shaar_error_code (*)(void*, PrivateSessionRegistry::Session*);
  using ScopePolicy = shaar_error_code (*)(shaar_scope, shaar_operation);
  Open open = nullptr;
  Close close = nullptr;
  ScopePolicy scope_policy = nullptr;
};

shaar_error_code OpenPrivateSessionHandler(
    void* context,
    Profile* parent,
    const std::string& profile_id,
    const std::string& session_id,
    PrivateSessionRegistry::Session** out);
shaar_error_code ClosePrivateSessionHandler(
    void* context,
    PrivateSessionRegistry::Session* session);
shaar_error_code PrivateSessionScopePolicy(shaar_scope scope,
                                           shaar_operation operation);
shaar_error_code EmitPrivateSessionStateEvent(
    shaar_engine* engine,
    const std::string& profile_id,
    const std::string& session_id,
    PrivateSessionRegistry::EventState state);
std::unique_ptr<PrivateSessionRegistry> CreatePrivateSessionRegistry(
    shaar_engine* engine);

}  // namespace shaar

extern "C" void shaar_private_sessions_register(
    ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_MODULE_H_
