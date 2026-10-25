# Native browser architecture

The development app uses a SwiftUI/AppKit interface and a pinned ArdiaCore Chromium framework through a direct Objective-C++ bridge. It does not use the upstream React Native or Expo adapter. The native shell includes spaces, profiles, tabs, pinning, session persistence, and command search across tabs and spaces.

Related: [[Profile_Space_Isolation]], [[Native_Window_Ownership]].
