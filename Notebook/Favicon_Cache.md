# Favicon cache

Favorites and pinned tabs keep their last known site icon so the sidebar shows real icons at launch, before any page loads. Ordinary tabs show only the live engine icon.

`FaviconCache` stores one PNG per item under `favicons/<profile UUID>/<item UUID>.png` in the application support directory, next to `workspace.json`. Favorites are keyed by Favorite ID and pinned tabs by their shared pin ID, so every window, including new ones, restores the same icon. Profiles never share entries.

`BrowserEngine` forwards each favicon Chromium reports for a Favorite page or pinned tab; the cache redraws it into a 64-pixel sRGB bitmap and rewrites the file only when the pixels change. A page without a favicon leaves the saved icon in place. Each workspace save drops icons whose Favorite, pin or profile no longer exists. Profiles hold at most 512 icons, and files above 64 KB are ignored at launch. Private windows have no cache.

Related: [[Profile_Favorites]], [[Managed_Workspace_Persistence]], [[Sidebar_Tab_Organization]].
