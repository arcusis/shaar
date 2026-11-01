# Swift and Chromium interoperability

Native UI uses SwiftUI/AppKit. Web pages use the pinned ArdiaCore Chromium framework. The local public [ArdiaCore header](../ThirdParty/ArdiaCore/ArdiaCore.h) exposes Objective-C AppKit objects; its [service header](../ThirdParty/ArdiaCore/ac_engine.h) exposes a C ABI. [Package.swift](../Package.swift) gives Swift a `ChromiumBridge` module around those interfaces.

The adapter loads the framework, owns engine/profile/tab/window objects, returns native views, translates callbacks and validates ownership. These responsibilities remain necessary with Chromium. They do not require rebuilding Chromium in Swift. The adapter's Objective-C++ implementation also uses C++ containers for engine launch arguments and dynamic C service calls.

Objective-C++ is an implementation choice, not a requirement for every browser feature. The upstream API is substantially Objective-C/C; a stable Swift-importable module could reduce wrapping. That alternative needs ABI, lifecycle and update evaluation before a rewrite. Keep feature state/UI in Swift and the engine adapter narrow.

The JavaScript files under `Tests/Fixtures/ProfileExtension` are authored MV3 test-extension fixtures. The bridge also injects main-world media and bounded bug-report diagnostic scripts because the pinned engine lacks the required media-session API and DevTools event delivery; see [[Media_Playback]] and [[Developer_Bug_Reports]]. Swift probe code evaluates page/extension expressions for diagnostics. The application shell remains native SwiftUI/AppKit, and web pages execute their own JavaScript through Chromium.

Probe code lives in the separate `ShaarVerification` executable, and test-only engine entry points in the `ChromiumBridge.Verification` submodule that the app never imports; see [[Verification_Harness]].

Related: [[Browser_Architecture]], [[Native_Window_Ownership]], [[Engine_Source_Build]], [[Source_And_Native_Verification]].
