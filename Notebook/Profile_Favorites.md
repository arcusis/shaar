# Profile-wide Favorites

Favorites belong to a Profile and appear above the Space title in every Space using that Profile. Space pins and folders remain Space-owned. Within one window, switching between shared-Profile Spaces selects the same live Favorite page; a second window owns a separate page identity. Different Profiles never reuse that page or its account context.

Adding an ordinary or pinned tab to Favorites promotes its existing page identity, retaining its document. Closing a Favorite page follows Chromium's close decision and keeps the shared definition. Selecting the closed Favorite creates a new window-local page at its original URL. Reset navigates an existing page through the native engine API; live navigation updates its current URL while the saved original URL stays unchanged. Removing a Favorite preserves existing documents as ordinary tabs and retains peer windows' current Space/Profile focus.

Shared definitions and ordering live in the workspace catalog; live page state and selection belong to each window. Session v4 and workspace v2 retain legacy migration support and reject incomplete modern Favorite state. Grid reordering rejects foreign or stale drag payloads. The grid scrolls beyond three visible rows without limiting the number of Favorites.


Related: [[Favicon_Cache]], [[Profile_Space_Isolation]], [[Native_Window_Ownership]], [[Managed_Workspace_Persistence]], [[Sidebar_Tab_Organization]].
