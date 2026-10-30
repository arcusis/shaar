# Arc reference library

Primary UI reference: user-supplied Arc macOS Settings screenshots. Preserve toolbar navigation, profile list/counts, grouped controls, spacing and native focus behavior. Screenshots do not establish animation timing. Personal account details are not published.

The live [Arc Help Center](https://resources.arc.net/hc/en-us) API returned 22 articles. Reachable historical English categories/sections/articles were collected through Internet Archive; original URLs, actual capture timestamps, request outcomes, source hashes and media references are recorded in the [reference manifest](../data/arc-reference/manifest.json).

Collection: 130 archived page requests; 113 HTTP 200 responses including 98 article bodies; 17 HTTP failures; no pending links in the discovered frontier. Wildcard CDX enumeration failed, so this is not proof of complete historical coverage. HTTP success alone is not article validation. Compressed source responses were decoded before link discovery; raw and decoded hashes remain distinct. Source HTML stays in the private local research cache, outside published repository files.

Key behavior references:

- [Profiles and shared account data](https://web.archive.org/web/20250518131450/https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing)
- [Library and recent file hover/drag](https://web.archive.org/web/20250419112858/https://resources.arc.net/hc/en-us/articles/19230634389911-Library-A-home-for-your-downloads-archived-tabs-easels-and-more)
- [Auto Archive](https://web.archive.org/web/20250515004423/https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go)
- [Per-profile download location](https://web.archive.org/web/20250514235418/https://resources.arc.net/hc/en-us/articles/25614213458711-How-Do-You-Change-Your-Download-Location-in-Arc-for-Desktop)
- [Peek](https://web.archive.org/web/20250515003853/https://resources.arc.net/hc/en-us/articles/19335302900887-Peek-Preview-Sites-From-Pinned-Tabs)
- [Little Arc](https://web.archive.org/web/20250415144655/https://resources.arc.net/hc/en-us/articles/19235387524503-Little-Arc-Quick-Lookups-Instant-Triaging)
- [Keyboard shortcuts](https://web.archive.org/web/20250429211829/https://resources.arc.net/hc/en-us/articles/20595231349911-Keyboard-Shortcuts)
- [Custom shortcut editing](https://web.archive.org/web/20250429211829/https://resources.arc.net/hc/en-us/articles/25622899860631-How-to-Set-Custom-Keyboard-Shortcuts-on-Arc-for-Desktop)

Media inventory has 87 unique references, including 11 GIF URLs. 3 GIF files were retrieved into the private local cache; 8 remain unavailable after live/archive requests. Use official captures for state transitions and motion study; verify source date and distinguish demonstration frame timing from application animation curves. Missing/blocked assets stay unverified. Live data and archived versions can differ.

Open-source comparison:

- [Ardia](https://github.com/mantrakp04/ardia): Chromium-backed UI with Expo/React Native macOS shell. Useful sidebar, launcher, theme and interaction reference; current project keeps SwiftUI/AppKit chrome. Source architecture is documented in its README; product/runtime quality is not independently accepted here.
- [Kylmora](https://github.com/kylmora/kylmora): native AppKit shell over system WebKit. Useful native window/settings/Space ownership reference; its engine differs from this project's Chromium target. README feature/performance claims remain upstream claims.
- [DuckDuckGo Apple browsers](https://github.com/duckduckgo/apple-browsers): native browser source and documented Bitwarden desktop-integration precedent. Our browser's eligibility for that vendor pairing remains unverified.

Refero and Mobbin searches returned unrelated web/password-manager or Arcade screens, not faithful Arc macOS Settings. Those results are not design evidence. Supplied screenshots and official Arc references stay primary.

Latest UI direction from user feedback: compact Profile-wide Favorites tiles above a small Space title; Space-specific pinned folders/tabs below; Library/recent-file hover at bottom-left; Space selectors and Add Space at bottom-right. Separate issues track [page sizing/top dragging #77](https://github.com/arcusis/shaar/issues/77), [Favorites #78](https://github.com/arcusis/shaar/issues/78), [custom RGB colors #79](https://github.com/arcusis/shaar/issues/79), and [chrome/dialogs/menus #80](https://github.com/arcusis/shaar/issues/80). Page containment and blank top chrome dragging come first; compact sidebar and native editing follow. Favorites require Profile-owned definitions with window-owned live documents, not duplicate ordinary tabs per Space. Preserve website account isolation.

Rechecked archived Favorites, Library and Folders article bodies against the manifest on 2026-10-25; decoded HTML hashes match. Favorites documentation describes an icon grid above Space titles; Library documents bottom-left access and recent-file hover/drag. The archived [Folders demonstration](https://web.archive.org/web/20250419111740/https://downloads.intercomcdn.com/i/o/558655555/b59f43c1781a6fc716f21415/folders.gif) shows a bottom-right plus menu and immediate inline naming of an Untitled folder. This supports replacing the current large creation form with inline sidebar editing. The demo is historical; cloud sharing, Easels, Notes and Boosts shown there are outside this implementation. Its HTTP body is gzip-compressed; raw SHA-256 `992e9fa3e5ebaff727c23b70a9cee33bc1155127c125c556cc404d1b74d1e176`, decoded GIF SHA-256 `e09996a7c379cdc4192ed5bc22c62407718dd67b6eb985384a8edfb81323ed69`; 62 frames. Private local frames stay outside the repository. Live media returned HTTP 410; the Favorites GIF also remained unavailable through the checked archive URL. No exact Arc motion timing is established.

Pinned Ardia UI comparison at `91e17a5655519d2dc385ec8452432469232ff9af`: `sidebar/PinnedGrid.tsx`, `Sidebar.tsx`, `settings/ThemeEditor.tsx`, `WindowToolbar.tsx` and `sidebar/Fold.tsx`. Its folder collapse uses a 150 ms custom curve; this is an Ardia implementation choice, not measured Arc parity. Borrow compact structure, bounded transitions and real custom color controls through native SwiftUI/AppKit. Materials need Reduce Transparency fallback; motion needs Reduce Motion fallback.

Related: [[Arc_Settings_Design]], [[Native_Password_Manager_Options]], [[Download_Library]], [[Profile_Space_Isolation]].
