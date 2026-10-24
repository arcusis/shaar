// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ArcusisBrowser",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["ArcusisBrowser"])],
  targets: [
    .target(name: "BrowserCore"),
    .target(
      name: "ChromiumBridge",
      publicHeadersPath: "include",
      cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(name: "ArcusisBrowser", dependencies: ["BrowserCore", "ChromiumBridge"]),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(name: "BrowserAppTests", dependencies: ["ArcusisBrowser"]),
  ]
)
