// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_PRINTING_SHAAR_PRINT_H_
#define CHROME_BROWSER_SHAAR_PRINTING_SHAAR_PRINT_H_

#include <string_view>

#include "base/functional/callback_forward.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace content {
class RenderFrameHost;
class WebContents;
}  // namespace content

namespace shaar::printing {

bool IsActive();
void Request(content::WebContents* contents,
             content::RenderFrameHost* frame,
             base::OnceCallback<void(bool)> decision);
shaar_error_code Resolve(shaar_engine* engine,
                         std::string_view request_id,
                         bool accepted);

}  // namespace shaar::printing

#endif  // CHROME_BROWSER_SHAAR_PRINTING_SHAAR_PRINT_H_
