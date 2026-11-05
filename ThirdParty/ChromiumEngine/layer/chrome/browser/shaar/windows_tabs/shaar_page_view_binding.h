// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_PAGE_VIEW_BINDING_H_
#define CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_PAGE_VIEW_BINDING_H_

#include "chrome/browser/shaar/public/shaar_engine.h"

class Browser;

namespace content {
class WebContents;
}

namespace shaar::windows_tabs {
void ReleasePageHost(shaar_window* window);
void ShowSelectedWebContents(content::WebContents* previous,
                             content::WebContents* selected);
void ActivatePageHost(shaar_window* window, Browser* browser,
                      content::WebContents* previous,
                      content::WebContents* selected);
}  // namespace shaar::windows_tabs

#endif  // CHROME_BROWSER_SHAAR_WINDOWS_TABS_SHAAR_PAGE_VIEW_BINDING_H_
