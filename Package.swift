// swift-tools-version: 6.2
import Foundation
import PackageDescription

let nativeBitwardenOrganizationCandidate =
  ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE"] == "1"
let nativeBitwardenSDKEnabled =
  nativeBitwardenOrganizationCandidate
  || ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_SDK"] == "1"
let nativeBitwardenSDKDependency: [Package.Dependency] =
  nativeBitwardenSDKEnabled
  ? [
    .package(
      path: nativeBitwardenOrganizationCandidate
        ? "build/NativeBitwardenOrganizationSDK/Package" : "build/NativeBitwardenSDK/Package")
  ]
  : []
let nativeBitwardenSDKProduct: [Target.Dependency] =
  nativeBitwardenSDKEnabled
  ? [.product(name: "ArcusisBitwardenSDK", package: "Package")]
  : []
let nativeBitwardenSDKLinkerSettings: [LinkerSetting] =
  nativeBitwardenSDKEnabled
  ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
  : []

let nativeBitwardenSwiftSettings: [SwiftSetting] =
  nativeBitwardenOrganizationCandidate
  ? [.define("ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE")] : []

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
      swiftSettings: nativeBitwardenSwiftSettings,
      linkerSettings: nativeBitwardenSDKLinkerSettings),
    .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
    .testTarget(
      name: "BrowserAppTests",
      dependencies: ["ArcusisBrowser", "BrowserCore"] + nativeBitwardenSDKProduct,
      swiftSettings: nativeBitwardenSwiftSettings),
  ]
)
