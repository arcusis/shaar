// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_FIND_SHAAR_PAGE_ZOOM_H_
#define CHROME_BROWSER_SHAAR_FIND_SHAAR_PAGE_ZOOM_H_

namespace shaar::page_zoom {

double NextPresetZoomLevel(double current_level, int direction);

} // namespace shaar::page_zoom

#endif // CHROME_BROWSER_SHAAR_FIND_SHAAR_PAGE_ZOOM_H_
