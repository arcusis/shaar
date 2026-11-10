# Favicon cache

Favorites, pinned tabs, and ordinary tabs keep their last known site icon so the sidebar can show it before that page loads again.

`FaviconCache` stores one PNG per item under `favicons/<profile UUID>/<item UUID>.png` in the application support directory, next to `workspace.json`. Favorites are keyed by Favorite ID and pinned tabs by their shared pin ID, so every window, including new ones, restores the same icon. Ordinary tabs use their tab ID. Profiles never share entries.

`BrowserEngine` forwards each favicon Chromium reports. The cache redraws it into a 64-pixel sRGB bitmap and rewrites the file only when the pixels change. An empty favicon query for the same site leaves the icon in place; a different site replaces it. Pinning, unpinning, and moving a page to or from Favorites copies the icon the sidebar is already showing onto the new key after the workspace save, because that save drops ids that are no longer a Favorite, pin, or saved tab. Profiles hold at most 512 icons, and files above 64 KB are ignored at launch. Private windows show the live icon and do not write the cache.

Related: [[Profile_Favorites]], [[Managed_Workspace_Persistence]], [[Sidebar_Tab_Organization]].
