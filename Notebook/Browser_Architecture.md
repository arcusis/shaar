# Native browser architecture

The development app uses a SwiftUI/AppKit interface and the pinned Shaar Chromium framework through a direct Objective-C++ bridge. The native shell includes spaces, profiles, tabs, pinning, session persistence, and command search across tabs and spaces. Some features still need native Shaar support; unsupported calls fail closed.

Related: [[Profile_Space_Isolation]], [[Native_Window_Ownership]].
