// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "ArcusisBrowser",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["ArcusisBrowser"])],
  targets: [
    .target(name: "BrowserCore"),
    .executableTarget(name: "ArcusisBrowser", dependencies: ["BrowserCore"]),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(name: "BrowserAppTests", dependencies: ["ArcusisBrowser"]),
  ]
)
