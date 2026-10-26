// swift-tools-version: 6.2
import Foundation
import PackageDescription

let nativeBitwardenSDKEnabled =
  ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_SDK"] == "1"
let nativeBitwardenSDKDependency: [Package.Dependency] =
  nativeBitwardenSDKEnabled
  ? [.package(path: "build/NativeBitwardenSDK/Package")]
  : []
let nativeBitwardenSDKProduct: [Target.Dependency] =
  nativeBitwardenSDKEnabled
  ? [.product(name: "ArcusisBitwardenSDK", package: "Package")]
  : []
let nativeBitwardenSDKLinkerSettings: [LinkerSetting] =
  nativeBitwardenSDKEnabled
  ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
  : []

let package = Package(
  name: "ArcusisBrowser",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["ArcusisBrowser"])],
  dependencies: nativeBitwardenSDKDependency,
  targets: [
    .target(name: "BrowserCore"),
    .target(
      name: "ChromiumBridge",
      publicHeadersPath: "include",
      cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(
      name: "ArcusisBrowser",
      dependencies: ["BrowserCore", "ChromiumBridge"] + nativeBitwardenSDKProduct,
      linkerSettings: nativeBitwardenSDKLinkerSettings),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(
      name: "BrowserAppTests",
      dependencies: ["ArcusisBrowser", "BrowserCore"] + nativeBitwardenSDKProduct),
  ]
)
