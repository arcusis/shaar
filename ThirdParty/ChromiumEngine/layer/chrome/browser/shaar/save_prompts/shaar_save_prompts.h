// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_SAVE_PROMPTS_SHAAR_SAVE_PROMPTS_H_
#define CHROME_BROWSER_SHAAR_SAVE_PROMPTS_SHAAR_SAVE_PROMPTS_H_

#include <string>
#include <string_view>

#include "base/functional/callback.h"
#include "chrome/browser/shaar/engine/shaar_module_registry.h"

namespace content {
class WebContents;
}
class GURL;

namespace shaar::save_prompts {

// Decision values shared with the embedder patch. 3 is only a new password.
constexpr int kDecisionSave = 1;
constexpr int kDecisionDismiss = 2;
constexpr int kDecisionNever = 3;

// Chromium calls this instead of opening a toolbar bubble. The callback runs
// once, including when the offer is declined immediately. True means the offer
// was delivered and the callback will run later.
bool OfferSavePrompt(content::WebContents* contents,
                     const char* prompt,
                     const char* detail,
                     bool update,
                     base::OnceCallback<void(int)> decision);

int DecisionCode(const char* prompt, bool update, const char* decision);
std::string SanitizeDetail(std::string_view raw);
GURL CleanPageURLForSavePrompt(const GURL& url);

// A private window, or a tab with no browser context, never gets a save offer.
bool SavePromptAllowedForContext(bool has_browser_context,
                                 bool off_the_record);

}  // namespace shaar::save_prompts

shaar_error_code HandleSavePromptOperation(
    shaar::ShaarEngineContext*, shaar_engine*, shaar_scope, shaar_window*,
    shaar_tab*, shaar_operation, shaar_bytes, shaar_request_id, shaar_reply_fn,
    void*, shaar_error*);
extern "C" void shaar_save_prompts_register(ShaarModuleRegistry* registry);

#endif  // CHROME_BROWSER_SHAAR_SAVE_PROMPTS_SHAAR_SAVE_PROMPTS_H_
