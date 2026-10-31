// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Sparkle lives in the app bundle's Frameworks directory.
let bundleFrameworksLinkerSettings: [LinkerSetting] = [
  .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
]

let package = Package(
  name: "ArcusisBrowser",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["ArcusisBrowser"])],
  dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
  targets: [
    .target(name: "BrowserCore", resources: [.process("Resources/public_suffix_list.dat")]),
    .target(
      name: "ChromiumBridge",
      publicHeadersPath: "include",
      cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(
      name: "ArcusisBrowser",
      dependencies: [
        "BrowserCore", "ChromiumBridge", .product(name: "Sparkle", package: "Sparkle"),
      ],
      linkerSettings: bundleFrameworksLinkerSettings),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(
      name: "BrowserAppTests",
      dependencies: ["ArcusisBrowser", "BrowserCore"]),
  ]
)
