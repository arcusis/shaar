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

let package = Package(
  name: "ArcusisBrowser",
  defaultLocalization: "en",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["Shaar"])],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
  targets: [
    .target(
      name: "BrowserCore",
      exclude: [
        "Resources/Core.xcstrings", "Resources/Bridge.xcstrings", "Resources/Shell.xcstrings",
        "Resources/Settings.xcstrings", "Resources/Panels.xcstrings",
      ],
      resources: [.process("Resources")],
      plugins: [.plugin(name: "CompileLocalizations")]),
    .plugin(
      name: "CompileLocalizations", capability: .buildTool(), path: "Plugins/CompileLocalizations"),
    .target(
      name: "ChromiumBridge",
      publicHeadersPath: "include",
      cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .target(
      name: "ArcusisBrowser",
      dependencies: [
        "BrowserCore", "ChromiumBridge", .product(name: "Sparkle", package: "Sparkle"),
      ]),
    .executableTarget(
      name: "Shaar", dependencies: ["ArcusisBrowser"],
      linkerSettings: bundleFrameworksLinkerSettings),
    // Engine probes. They use app internals through @testable import, so release builds of this
    // target need -enable-testing: build it with `bundle-app.sh --with-engine --verification`.
    .executableTarget(
      name: "ShaarVerification",
      dependencies: ["ArcusisBrowser", "BrowserCore", "ChromiumBridge"],
      linkerSettings: bundleFrameworksLinkerSettings),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(
      name: "BrowserAppTests",
      dependencies: ["ArcusisBrowser", "BrowserCore"]),
    .testTarget(
      name: "ShaarVerificationTests",
      dependencies: ["ArcusisBrowser", "BrowserCore", "ChromiumBridge", "ShaarVerification"]),
  ]
)
