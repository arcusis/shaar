// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_MEDIA_SHAAR_MEDIA_PERMISSION_H_
#define CHROME_BROWSER_SHAAR_MEDIA_SHAAR_MEDIA_PERMISSION_H_

#include <optional>
#include <string_view>

#include "base/functional/callback.h"
#include "chrome/browser/shaar/public/shaar_engine.h"

namespace content {
class WebContents;
struct MediaStreamRequest;
}

namespace shaar::media {

void StartCaptureObserving(shaar_engine* engine);
void StopCaptureObserving();

// Called only by Chromium's website camera/microphone handler. The callback
// owns the pending device decision and defaults to denial on every failure.
void RequestWebsiteMediaPermission(
    content::WebContents* contents, const content::MediaStreamRequest& request,
    base::OnceCallback<void(bool)> decision);

// A missing request returns nullopt. A stale or mismatched request resolves
// the held device callback as denied and returns false.
std::optional<bool> ResolveWebsiteMediaPermission(
    shaar_engine* engine, content::WebContents* contents,
    std::string_view request_id, bool accepted);

}  // namespace shaar::media

#endif  // CHROME_BROWSER_SHAAR_MEDIA_SHAAR_MEDIA_PERMISSION_H_
