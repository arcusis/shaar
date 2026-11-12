// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import PackageDescription

// Sparkle lives in the app bundle's Frameworks directory.
let bundleFrameworksLinkerSettings: [LinkerSetting] = [
  .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
]

let verificationBuild =
  ProcessInfo.processInfo.environment["SHAAR_PACKAGE_VERIFICATION_BUILD"] == "1"
var chromiumBridgeCxxSettings: [CXXSetting] = [.unsafeFlags(["-fobjc-arc"])]
if verificationBuild {
  chromiumBridgeCxxSettings.append(.define("SHAAR_VERIFICATION"))
}

let package = Package(
  name: "ArcusisBrowser",
  defaultLocalization: "en",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["Shaar"])],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
  targets: [
    .target(
      name: "BrowserCore",
      dependencies: ["CSQLite"],
      exclude: [
        "Resources/Core.xcstrings", "Resources/Bridge.xcstrings", "Resources/Shell.xcstrings",
        "Resources/Settings.xcstrings", "Resources/Panels.xcstrings",
        "Resources/Inspector.xcstrings", "Resources/InspectorDetails.xcstrings",
        "Resources/InspectorTools.xcstrings",
      ],
      resources: [.process("Resources")],
      plugins: [.plugin(name: "CompileLocalizations")]),
    .plugin(
      name: "CompileLocalizations", capability: .buildTool(), path: "Plugins/CompileLocalizations"),
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    .target(
      name: "ChromiumBridge",
      publicHeadersPath: "include",
      cxxSettings: chromiumBridgeCxxSettings,
      linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Security")]
    ),
    // BEGIN Shaar navigation C ABI shim.
    .target(
      name: "ShaarEngineABIC",
      path: "Sources/ShaarEngineABI/Navigation/CABI",
      publicHeadersPath: "include"),
    // BEGIN storage_keychain
    .target(
      name: "ShaarStorageKeychainABIC",
      path: "Sources/ShaarEngineABI/StorageKeychain/CABI",
      publicHeadersPath: "include"),
    // END storage_keychain
    .target(
      name: "ShaarEngineABI",
      dependencies: [
        "ShaarEngineC",
        "ShaarEngineABIC",
        // BEGIN storage_keychain
        "ShaarStorageKeychainABIC",
        // END storage_keychain
      ],
      exclude: [
        "Navigation/CABI",
        // BEGIN storage_keychain
        "StorageKeychain/CABI",
        // END storage_keychain
      ]),
    // END Shaar navigation C ABI shim.
    .target(name: "ShaarEngineC", publicHeadersPath: "include"),
    .target(
      name: "ChromiumBridgeVerification",
      dependencies: ["ChromiumBridge"],
      path: "Sources/ChromiumBridgeVerification",
      publicHeadersPath: "include",
      cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit"), .unsafeFlags(["-Xlinker", "-ObjC"])]
    ),
    .target(
      name: "ArcusisBrowser",
      dependencies: [
        "BrowserCore", "ChromiumBridge", "ShaarEngineABI",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [.copy("Resources/InspectorAudit")]),
    .executableTarget(
      name: "Shaar", dependencies: ["ArcusisBrowser"],
      linkerSettings: bundleFrameworksLinkerSettings),
    // Engine probes. They use app internals through @testable import, so release builds of this
    // target need -enable-testing: build it with `bundle-app.sh --with-engine --verification`.
    .executableTarget(
      name: "ShaarVerification",
      dependencies: [
        "ArcusisBrowser", "BrowserCore", "ChromiumBridge", "ChromiumBridgeVerification",
        "ShaarEngineABI",
      ],
      linkerSettings: bundleFrameworksLinkerSettings),
    .target(name: "BrowserTestSupport", path: "Tests/TestSupport"),
    .testTarget(
      name: "BrowserCoreTests", dependencies: ["BrowserCore", "BrowserTestSupport", "CSQLite"],
      resources: [.copy("Fixtures/BrowserImport")]),
    .testTarget(
      name: "BrowserAppTests",
      dependencies: [
        "ArcusisBrowser", "BrowserCore", "BrowserTestSupport", "ChromiumBridge",
        "ChromiumBridgeVerification", "ShaarEngineABI", "ShaarEngineC",
      ],
      resources: [.copy("Snapshots/InspectorAI")]),
    .testTarget(
      name: "ShaarVerificationTests",
      dependencies: [
        "ArcusisBrowser", "BrowserCore", "ChromiumBridge", "ChromiumBridgeVerification",
        "ShaarVerification",
      ]),
    .testTarget(name: "ShaarEngineABITests", dependencies: ["ShaarEngineABI", "ShaarEngineC"]),
  ]
)
