// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_JAVASCRIPT_DIALOGS_SHAAR_JAVASCRIPT_DIALOGS_H_
#define CHROME_BROWSER_SHAAR_JAVASCRIPT_DIALOGS_SHAAR_JAVASCRIPT_DIALOGS_H_

#include "content/public/browser/javascript_dialog_manager.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"

namespace content {
class WebContents;
}

namespace shaar::javascript_dialogs {

class Manager final : public content::JavaScriptDialogManager {
 public:
  Manager();
  ~Manager() override;

  void RunJavaScriptDialog(content::WebContents* web_contents,
                           content::RenderFrameHost* render_frame_host,
                           content::JavaScriptDialogType dialog_type,
                           const std::u16string& message_text,
                           const std::u16string& default_prompt_text,
                           DialogClosedCallback callback,
                           bool* did_suppress_message) override;
  void RunBeforeUnloadDialog(content::WebContents* web_contents,
                             content::RenderFrameHost* render_frame_host,
                             bool is_reload,
                             DialogClosedCallback callback) override;
  void CancelDialogs(content::WebContents* web_contents,
                     bool reset_state) override;

};

void Register(ShaarModuleRegistry* registry);
content::JavaScriptDialogManager* GetManager();
bool DialogMayBePresented(bool is_selected_tab, bool is_regular_profile);
bool SuppressedDialogAccepted(content::JavaScriptDialogType type);
shaar_error_code HandleJavaScriptDialogOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id, shaar_reply_fn,
    void*, shaar_error*);

}  // namespace shaar::javascript_dialogs

#endif  // CHROME_BROWSER_SHAAR_JAVASCRIPT_DIALOGS_SHAAR_JAVASCRIPT_DIALOGS_H_
