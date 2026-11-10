// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WEBSHARE_SHAAR_WEBSHARE_H_
#define CHROME_BROWSER_SHAAR_WEBSHARE_SHAAR_WEBSHARE_H_

#include <string_view>
#include <vector>

#include "base/functional/callback_forward.h"
#include "chrome/browser/shaar/public/shaar_engine.h"
#include "third_party/blink/public/mojom/webshare/webshare.mojom.h"

namespace content {
class RenderFrameHost;
}

class GURL;

namespace shaar::webshare {

using ShareCallback = base::OnceCallback<void(blink::mojom::ShareError)>;

bool IsActive();

// Returns false when Shaar is not active so Chromium can use its native path.
// When Shaar is active, this consumes the request or rejects it through the
// callback. Files are deliberately unsupported by the app share sheet.
bool Request(content::RenderFrameHost *frame, std::string_view title,
             std::string_view text, const GURL &share_url,
             std::vector<blink::mojom::SharedFilePtr> files,
             bool user_activated, ShareCallback callback);

shaar_error_code Resolve(shaar_engine *engine, std::string_view request_id,
                         bool shared);

} // namespace shaar::webshare

#endif // CHROME_BROWSER_SHAAR_WEBSHARE_SHAAR_WEBSHARE_H_
