// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_LOGIN_SHAAR_LOGIN_H_
#define CHROME_BROWSER_SHAAR_LOGIN_SHAAR_LOGIN_H_

#include <memory>

#include "content/public/browser/login_delegate.h"
#include "net/base/auth.h"

namespace content {
class WebContents;
}

namespace shaar::login {
std::unique_ptr<content::LoginDelegate> CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* web_contents,
    content::LoginDelegate::LoginAuthRequiredCallback callback);
}

#endif  // CHROME_BROWSER_SHAAR_LOGIN_SHAAR_LOGIN_H_
