// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "chrome/browser/shaar/devtools/shaar_devtools.h"

extern "C" void shaar_devtools_register(ShaarModuleRegistry* registry) {
  if (!registry)
    return;
  shaar::devtools::BindRuntimeServices();
  static const shaar::devtools::ModuleHandlers handlers{
      .handle_operation = &shaar::devtools::HandleDevToolsOperation};
  registry->RegisterModule(SHAAR_MODULE_DEVTOOLS, &handlers);
  registry->Register(SHAAR_OP_DEVTOOLS_CALL, SHAAR_OP_DEVTOOLS_CALL,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_PROBE_CAPTURE_TAB, SHAAR_OP_PROBE_CAPTURE_TAB,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_PROBE_TRUSTED_CLICK, SHAAR_OP_PROBE_NODE_LIVE,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_PROBE_TRUSTED_SCROLL,
                     SHAAR_OP_PROBE_TRUSTED_SCROLL,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_PROBE_POPUP_EVALUATE, SHAAR_OP_PROBE_POPUP_CAPTURE,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_PROBE_POPUP_TRUSTED_CLICK,
                     SHAAR_OP_PROBE_POPUP_TRUSTED_CLICK,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_PROBE_DEVTOOLS_OPEN_URL,
                     SHAAR_OP_PROBE_DEVTOOLS_FRONTEND_ATTACHED,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_DEVTOOLS_UI_SHOW, SHAAR_OP_DEVTOOLS_UI_STATE,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_DEVTOOLS_UI_SET_DOCK,
                     SHAAR_OP_DEVTOOLS_CONTROL_STATUS,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_DEVTOOLS_PANEL_OPEN,
                     SHAAR_OP_DEVTOOLS_PANEL_PHASE2_COMMAND,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST,
                     SHAAR_OP_DEVTOOLS_PANEL_SCREENCAST,
                     &shaar::devtools::HandleDevToolsOperation);
  registry->Register(SHAAR_OP_DEVTOOLS_VIEWPORT_OPEN,
                     SHAAR_OP_DEVTOOLS_VIEWPORT_FRAME,
                     &shaar::devtools::HandleDevToolsOperation);
}
