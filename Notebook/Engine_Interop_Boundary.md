# Swift and Chromium interoperability

Native UI uses SwiftUI/AppKit. Web pages use the pinned ArdiaCore Chromium framework. The local public [ArdiaCore header](../ThirdParty/ArdiaCore/ArdiaCore.h) exposes Objective-C AppKit objects; its [service header](../ThirdParty/ArdiaCore/ac_engine.h) exposes a C ABI. [Package.swift](../Package.swift) gives Swift a `ChromiumBridge` module around those interfaces.

The adapter loads the framework, owns engine/profile/tab/window objects, returns native views, translates callbacks and validates ownership. These responsibilities remain necessary with Chromium. They do not require rebuilding Chromium in Swift. The adapter's Objective-C++ implementation also uses C++ containers for engine launch arguments and dynamic C service calls.

Objective-C++ is an implementation choice, not a requirement for every browser feature. The upstream API is substantially Objective-C/C; a stable Swift-importable module could reduce wrapping. That alternative needs ABI, lifecycle and update evaluation before a rewrite. Keep feature state/UI in Swift and the engine adapter narrow.

The repository's four JavaScript files are authored MV3 test-extension fixtures under Tests/Fixtures/ProfileExtension. They test browser behavior; the application shell is not a JavaScript UI. Swift probe code also evaluates page/extension expressions for diagnostics. A native browser still renders websites containing JavaScript, and native autofill can require renderer-side form handling.

Verification scaffolding currently shares application/bridge compilation with product code. Preserve the ownership and credential-safety checks, but separate probe-only responsibilities from normal product paths before company release. A password-manager SDK would be a separate vendor integration and would not replace the browser-engine adapter.

Related: [[Browser_Architecture]], [[Native_Window_Ownership]], [[Native_Password_Manager_Options]], [[Source_And_Native_Verification]].
