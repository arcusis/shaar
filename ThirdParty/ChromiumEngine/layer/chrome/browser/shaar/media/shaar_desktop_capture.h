// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_MEDIA_SHAAR_DESKTOP_CAPTURE_H_
#define CHROME_BROWSER_SHAAR_MEDIA_SHAAR_DESKTOP_CAPTURE_H_

#include <memory>
#include <string_view>

#include "chrome/browser/media/webrtc/desktop_media_picker.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace content {
struct MediaStreamRequest;
}

namespace shaar::desktop_capture {

bool IsActive();
std::unique_ptr<DesktopMediaPicker> CreatePicker(
    const content::MediaStreamRequest& request);
shaar_error_code Resolve(shaar_engine* engine,
                         shaar_window* window,
                         shaar_tab* tab,
                         std::string_view prompt_id,
                         std::string_view decision,
                         std::string_view source_token);

}  // namespace shaar::desktop_capture

#endif  // CHROME_BROWSER_SHAAR_MEDIA_SHAAR_DESKTOP_CAPTURE_H_
