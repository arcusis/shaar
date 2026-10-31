// swift-tools-version: 6.2
import Foundation
import PackageDescription

let package = Package(
  name: "ArcusisBrowser",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["ArcusisBrowser"])],
  dependencies: [],
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
      dependencies: ["BrowserCore", "ChromiumBridge"]),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(
      name: "BrowserAppTests",
      dependencies: ["ArcusisBrowser", "BrowserCore"]),
  ]
)
