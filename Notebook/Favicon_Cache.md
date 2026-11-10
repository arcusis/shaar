# Favicon cache

Favorites and pinned tabs keep their last known site icon so the sidebar can show it before that page loads again.

`FaviconCache` stores one PNG per item under `favicons/<profile UUID>/<item UUID>.png` in the application support directory, next to `workspace.json`. Favorites are keyed by Favorite ID and pinned tabs by their shared pin ID, so every window, including new ones, restores the same icon. Profiles never share entries.

`BrowserEngine` asks Chromium for an icon when a tab changes. It writes the cache only for a pinned tab or Favorite, and only when that image changed. The saved file records the site host beside the PNG. An empty query for that same site, or a query that names no site, leaves the icon in place. A different site with no icon removes the live icon and the saved file, including on the first query after a restart. A PNG saved before that host file existed is skipped at launch and returns when the page loads again. Pinning a tab or saving a Favorite copies the shown icon onto the new key after the workspace save. Unpinning, turning a Favorite back into a tab, and moving an ordinary tab do not write a cache file. Profiles hold at most 512 icons, and files above 64 KB are ignored at launch. Private windows show the live icon and do not write the cache.

Related: [[Profile_Favorites]], [[Managed_Workspace_Persistence]], [[Sidebar_Tab_Organization]].
