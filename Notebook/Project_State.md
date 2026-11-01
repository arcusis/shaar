# Project overview and verification boundaries

Shaar ([[Product_Identity]]) is an early public beta macOS browser built with SwiftUI/AppKit and a pinned Chromium engine. Its architecture includes Profiles for isolated browser data, Spaces for tab organization, native and private windows, a command launcher, bookmarks/history, downloads, a sidebar media player and automatic picture-in-picture.

A Profile owns browser accounts, persistent engine data, and Profile preferences. A Space references a Profile and owns its tab organization and theme. Explicitly shared Profiles allow multiple Spaces to use the same website account data. Each native window owns its live tab identities and selection.

Source builds and authored fixtures establish only their stated code and integration boundaries. They do not by themselves establish physical input behavior, compatibility with external services, release provenance, signing, notarization or distribution. See [[Source_And_Native_Verification]] and [[Build_And_Run]].

As of 2026-11-01, the Notebook is reconciled against `production` at `295d63b`: media mini player (#326), automatic PiP and controls (#329), durable snapshots (#331), the separate verification identifier (#330), and Quit/background-mode fixes (#332) are merged. See [[Media_Playback]], [[Automatic_Picture_In_Picture]], [[Picture_In_Picture_Controls]], [[Session_Durability]], [[Verification_Harness]] and [[Quit_Exit_Verification]]. Site control center (#327) remains open; [[Site_Control_Center]] explicitly describes pending branch behavior. The engine source-build runner exists, but normal bundles use the pinned prebuilt engine; see [[Engine_Source_Build]].

Related: [[Product_Identity]], [[Arc_Settings_Design]], [[Profile_Space_Isolation]], [[Notebook_Maintenance]].
