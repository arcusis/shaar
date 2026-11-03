// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_MODULE_H_
#define CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_MODULE_H_

#include <unordered_map>

#include "chrome/browser/shaar/private-sessions/shaar_private_sessions.h"
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

// Temporary module registry declaration. The lifecycle module owns the shared
// definition when it lands; private-sessions contributes its registration
// entry and direct handlers to this contract.
class ShaarModuleRegistry {
 public:
  bool Register(uint32_t module_id, PrivateSessionModuleHandlers handlers);
  const PrivateSessionModuleHandlers* Find(uint32_t module_id) const;

 private:
  std::unordered_map<uint32_t, PrivateSessionModuleHandlers> handlers_;
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
    shaar::ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_PRIVATE_SESSIONS_SHAAR_PRIVATE_SESSIONS_MODULE_H_
