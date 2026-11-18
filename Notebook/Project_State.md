# Project overview and verification boundaries

Shaar ([[Product_Identity]]) is an early public beta macOS browser built with SwiftUI/AppKit and a pinned Chromium engine. Its architecture includes Profiles for isolated browser data, Spaces for tab organization, native and private windows, a command launcher, bookmarks/history, downloads, a sidebar media player and automatic picture-in-picture.

A Profile owns browser accounts, persistent engine data, and Profile preferences. A Space references a Profile and owns its tab organization and theme. Explicitly shared Profiles allow multiple Spaces to use the same website account data. Each native window owns its live tab identities and selection.

Source builds and authored fixtures establish only their stated code and integration boundaries. They do not by themselves establish physical input behavior, compatibility with external services, release provenance, signing, notarization or distribution. See [[Source_And_Native_Verification]] and [[Build_And_Run]].

The current production line pins Chromium `157.0.8103.51-shaar.50` and shipped Shaar `v0.2.0` on 2026-11-17. The release includes Chromium discard/freeze support for sleeping tabs and the website permission sheet, while the SwiftUI DevTools panels remain retired. See [[Chromium_157_Release_Notes]], [[Chromium_157_Release_Runbook]], [[Shaar_DevTools_SwiftUI_Retirement]], [[Media_Consent]] and [[Chromium_157_Release_QA]].

The current production fixes include base runtime feature defaults (#3743), restored nested extension-tab activation through the host-caused activation path (#3744), sanitizer-safe benchmark timing (#3745), hardened browser file and SQLite imports (#3746, #3747), profile-handle cleanup at engine stop (#3749), and a shared once-only engine reply registry (#3750). Website deploy checks are gated behind the full check workflow (#3742); deployment remains manual when `CLOUDFLARE_API_TOKEN` is unset (#3748). See [[Chromium_157_Release_Notes]], [[Chromium_157_Release_QA]], [[Engine_Module_lifecycle]], [[Engine_Module_extensions]], [[Engine_Interop_Boundary]], [[CI_Pipeline]], [[Public_Website_Design]] and [[Build_And_Run]].

The current production source is the authority for implementation state. Source and authored fixtures establish only their stated code and integration boundaries, not shipping-engine behavior or release provenance. See [[Shaar_State]] for the module map and [[Source_And_Native_Verification]] for proof boundaries. The engine source-build runner exists, but normal bundles use the pinned prebuilt engine; see [[Engine_Source_Build]].

Related: [[Product_Identity]], [[Arc_Settings_Design]], [[Profile_Space_Isolation]], [[Notebook_Maintenance]].
