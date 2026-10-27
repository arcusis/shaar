// swift-tools-version: 6.2
import Foundation
import PackageDescription

let strictSDK8 = ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK"] == "1"
let strictSDK9 = ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_SERVICE_SDK"] == "1"
let strictSDK10 = ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_NORMALIZATION_SDK"] == "1"
if strictSDK8 && strictSDK9 {
  fatalError("Strict SDK8 and SDK9 selections are mutually exclusive")
}
if strictSDK10 && (strictSDK8 || strictSDK9) {
  fatalError("Strict SDK10 cannot be combined with another strict SDK selection")
}
let strictSDK = strictSDK8 || strictSDK9 || strictSDK10
let strictFixture =
  ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_STRICT_FIXTURE"] == "1"
if strictFixture && !strictSDK {
  fatalError("Strict SDK fixture requires SDK8, SDK9, or SDK10 selection")
}
if strictSDK
  && [
    "ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE", "ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE",
    "ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE", "ARCUSIS_NATIVE_BITWARDEN_SDK",
  ].contains(where: { ProcessInfo.processInfo.environment[$0] == "1" })
{
  fatalError("Strict SDK cannot be combined with legacy SDK selection")
}
let nativeBitwardenRefreshFixture =
  strictFixture
  || ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE"] == "1"
let nativeBitwardenRefreshCandidate =
  strictSDK || nativeBitwardenRefreshFixture
  || ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE"] == "1"
let nativeBitwardenOrganizationCandidate =
  nativeBitwardenRefreshCandidate
  || ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE"] == "1"
let nativeBitwardenSDKEnabled =
  nativeBitwardenOrganizationCandidate
  || ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_BITWARDEN_SDK"] == "1"
let nativeBitwardenSDKDependency: [Package.Dependency] =
  nativeBitwardenSDKEnabled
  ? [
    .package(
      path: strictSDK
        ? (strictSDK10
          ? (strictFixture
            ? "build/NativeBitwardenStrictSDK10/Package-debug"
            : "build/NativeBitwardenStrictSDK10/Package-release")
          : strictSDK9
          ? (strictFixture
            ? "build/NativeBitwardenStrictSDK9/Package-debug"
            : "build/NativeBitwardenStrictSDK9/Package-release")
          : (strictFixture
            ? "build/NativeBitwardenStrictSDK8/Package-debug"
            : "build/NativeBitwardenStrictSDK8/Package-release"))
        : nativeBitwardenRefreshFixture
          ? "build/NativeBitwardenRefreshSDK7Fixture/Package"
          : (nativeBitwardenRefreshCandidate
            ? "build/NativeBitwardenRefreshSDK7/Package"
            : (nativeBitwardenOrganizationCandidate
              ? "build/NativeBitwardenOrganizationSDK/Package" : "build/NativeBitwardenSDK/Package"))
    )
  ]
  : []
let nativeBitwardenSDKProduct: [Target.Dependency] =
  nativeBitwardenSDKEnabled
  ? [
    .product(
      name: "ArcusisBitwardenSDK",
      package: strictSDK ? (strictFixture ? "package-debug" : "package-release") : "Package")
  ]
  : []
let nativeBitwardenSDKLinkerSettings: [LinkerSetting] =
  nativeBitwardenSDKEnabled
  ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
  : []

let nativeBitwardenSwiftSettings: [SwiftSetting] =
  (strictSDK ? [.define("ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK")] : [])
  + (nativeBitwardenOrganizationCandidate
    ? [.define("ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE")] : [])
  + (nativeBitwardenRefreshCandidate
    ? [.define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE")] : [])
  + (nativeBitwardenRefreshFixture
    ? [.define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE")] : [])

let package = Package(
  name: "ArcusisBrowser",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "ArcusisBrowser", targets: ["ArcusisBrowser"])],
  dependencies: nativeBitwardenSDKDependency,
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
