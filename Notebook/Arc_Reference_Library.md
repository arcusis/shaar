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

Related: [[Arc_Settings_Design]], [[Native_Password_Manager_Options]], [[Download_Library]], [[Profile_Space_Isolation]].
