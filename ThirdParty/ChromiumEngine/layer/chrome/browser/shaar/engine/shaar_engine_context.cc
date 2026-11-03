// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/engine/shaar_engine_context.h"

namespace shaar {
namespace {
ShaarEngineContext g_context;
}  // namespace

ShaarEngineContext& EngineContext() {
  return g_context;
}

void SetProfileServices(ProfileServices* services) {
  g_context.profile_services = services;
}

void SetBrowserTabRegistry(BrowserTabRegistry* registry) {
  g_context.browser_tabs = registry;
}
// BEGIN site_data
void SetPrivateSessionServices(PrivateSessionServices* services) {
  g_context.private_sessions = services;
}
// END site_data
}  // namespace shaar
