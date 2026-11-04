# Swift and Chromium interoperability

Native UI uses SwiftUI/AppKit. Web pages use the pinned Shaar Chromium framework. The [Shaar engine header](../ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h) defines the C ABI. [Package.swift](../Package.swift) gives Swift a `ChromiumBridge` module around that interface.

The adapter loads the framework, owns engine/profile/tab/window handles, returns native views, translates callbacks and validates ownership. These responsibilities remain necessary with Chromium. They do not require rebuilding Chromium in Swift.

Objective-C++ is an implementation choice, not a requirement for every browser feature. Keep feature state/UI in Swift and the engine adapter narrow.

The JavaScript files under `Tests/Fixtures/ProfileExtension` are authored MV3 test-extension fixtures. The bridge retains media-session and picture-in-picture declarations, but native Shaar coverage remains incomplete; see [[Media_Playback]]. Swift probe code evaluates page/extension expressions for diagnostics. The application shell remains native SwiftUI/AppKit, and web pages execute their own JavaScript through Chromium.

Probe code lives in the separate `ShaarVerification` executable, and test-only engine entry points in the `ChromiumBridge.Verification` submodule that the app never imports; see [[Verification_Harness]].

Related: [[Browser_Architecture]], [[Native_Window_Ownership]], [[Engine_Source_Build]], [[Source_And_Native_Verification]].
