# Arc design references

Arc by The Browser Company is a primary visual reference for Shaar's macOS browser chrome. Shaar uses Arc's documented concepts as design input while implementing an independent SwiftUI/AppKit interface and Chromium engine. Reference material informs layout and interaction direction; it does not establish exact motion behavior or feature parity.

Useful design references include profile-separated browsing data, a Library for downloads and saved content, compact Favorites above Space navigation, per-profile download locations, Peek previews, Little Arc quick windows, and configurable keyboard shortcuts. Shaar adapts these ideas to its own Profile, Space, window, and document ownership model. See [[Arc_Settings_Design]], [[Profile_Space_Isolation]], [[Profile_Favorites]], [[Library_Drawer]], and [[Keyboard_Commands]].

Public Arc sources consulted:

- [Arc Help Center](https://resources.arc.net/hc/en-us)
- [Profiles: separate work and personal browsing](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing)
- [Library: downloads, archived tabs, and Easels](https://resources.arc.net/hc/en-us/articles/19230634389911-Library-A-home-for-your-downloads-archived-tabs-easels-and-more)
- [Auto Archive](https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go)
- [Change download location](https://resources.arc.net/hc/en-us/articles/25614213458711-How-Do-You-Change-Your-Download-Location-in-Arc-for-Desktop)
- [Peek previews](https://resources.arc.net/hc/en-us/articles/19335302900887-Peek-Preview-Sites-From-Pinned-Tabs)
- [Little Arc](https://resources.arc.net/hc/en-us/articles/19235387524503-Little-Arc-Quick-Lookups-Instant-Triaging)
- [Keyboard shortcuts](https://resources.arc.net/hc/en-us/articles/20595231349911-Keyboard-Shortcuts)
- [Customize keyboard shortcuts](https://resources.arc.net/hc/en-us/articles/25622899860631-How-to-Set-Custom-Keyboard-Shortcuts-on-Arc-for-Desktop)
- [Arc release notes](https://start.arc.net/release-notes)

These pages describe Arc products and are cited as design references. Their descriptions, feature behavior, and availability may change; Shaar behavior is defined by this repository's implementation.
