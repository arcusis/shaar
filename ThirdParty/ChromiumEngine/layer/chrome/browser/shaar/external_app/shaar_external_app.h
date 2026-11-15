// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_EXTERNAL_APP_SHAAR_EXTERNAL_APP_H_
#define CHROME_BROWSER_SHAAR_EXTERNAL_APP_SHAAR_EXTERNAL_APP_H_

#include <optional>
#include <string>

#include "url/gurl.h"
#include "url/origin.h"

namespace content {
class WebContents;
}

namespace shaar::external_app {

// Returns true when the active Shaar engine owns the external protocol flow.
bool Request(const GURL& url, content::WebContents* contents,
             const std::optional<url::Origin>& origin,
             const std::u16string& application_name);

}  // namespace shaar::external_app

#endif  // CHROME_BROWSER_SHAAR_EXTERNAL_APP_SHAAR_EXTERNAL_APP_H_
