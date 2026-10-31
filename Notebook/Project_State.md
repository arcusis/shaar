# Project overview and verification boundaries

Shaar ([[Product_Identity]]) is an independent macOS browser built with SwiftUI/AppKit and a pinned Chromium engine. Its architecture includes Profiles for isolated browser data, Spaces for tab organization, native windows, a command launcher, bookmarks/history, downloads.

A Profile owns browser accounts, persistent engine data, and Profile preferences. A Space references a Profile and owns its tab organization and theme. Explicitly shared Profiles allow multiple Spaces to use the same website account data. Each native window owns its live tab identities and selection.

Source builds and authored fixtures establish only their stated code and integration boundaries. They do not by themselves establish physical input behavior, compatibility with external services, release provenance, signing, notarization or distribution. See [[Source_And_Native_Verification]] and [[Build_And_Run]].

Related: [[Product_Identity]], [[Arc_Settings_Design]], [[Profile_Space_Isolation]].
