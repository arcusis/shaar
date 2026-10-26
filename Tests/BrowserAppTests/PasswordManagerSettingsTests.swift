import AppKit
import BrowserCore
import Foundation
import PDFKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PasswordManagerSettingsTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_SETTINGS_CAPTURE"] == "1",
      "Native rendering requires explicit desktop authorization."))
  func nativeSettingsComponentRendersOffAndUnavailableStates() async throws {
    _ = NSApplication.shared
    let profile = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let outputDirectory = URL(fileURLWithPath: "build/Verification/native-bitwarden-settings")
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)

    var captures: [[String: Any]] = []
    for colorScheme in [ColorScheme.light, .dark] {
      for enabled in [false, true] {
        let preferences = BrowserPreferencesStore()
        let controller = NativeBitwardenController(
          preferences: preferences, backend: NativeBitwardenSDKBackend())
        controller.selectProfile(profile)
        if enabled { controller.setEnabled(true) }

        let theme = colorScheme == .dark ? "dark" : "light"
        let state = enabled ? "enabled" : "off"
        let filename = "native-bitwarden-\(state)-\(theme).png"
        let imageURL = outputDirectory.appendingPathComponent(filename)
        let pixels = try await renderNativeSettings(
          controller: controller, colorScheme: colorScheme, to: imageURL)
        captures.append([
          "file": filename,
          "width": pixels.width,
          "height": pixels.height,
          "profile": profile.uuidString.lowercased(),
          "sdkAvailable": controller.sdkAvailable,
          "enabled": controller.isEnabled,
          "challengeState": "none",
          "status": controller.status,
          "colorScheme": theme,
          "rendering":
            "PasswordManagerSettingsView in un-ordered NSHostingView via PDFKit rasterization",
        ])
      }
    }

    let challengePreferences = BrowserPreferencesStore()
    let challengeController = NativeBitwardenController(
      preferences: challengePreferences, backend: SyntheticChallengeBackend())
    challengeController.selectProfile(profile)
    challengeController.setEnabled(true)
    challengeController.email = "person@example.test"
    challengeController.masterPassword = "synthetic-password"
    challengeController.connect()
    for _ in 0..<100 where challengeController.supportedMFAProviders.isEmpty {
      await Task.yield()
    }
    #expect(challengeController.supportedMFAProviders == [.authenticator, .email])
    for colorScheme in [ColorScheme.light, .dark] {
      let theme = colorScheme == .dark ? "dark" : "light"
      let filename = "native-bitwarden-challenge-\(theme).png"
      let imageURL = outputDirectory.appendingPathComponent(filename)
      let pixels = try await renderNativeSettings(
        controller: challengeController, colorScheme: colorScheme, to: imageURL)
      captures.append([
        "file": filename,
        "width": pixels.width,
        "height": pixels.height,
        "profile": profile.uuidString.lowercased(),
        "sdkAvailable": challengeController.sdkAvailable,
        "enabled": challengeController.isEnabled,
        "challengeState": "synthetic-supported-code-mfa",
        "syntheticChallenge": true,
        "status": challengeController.status,
        "colorScheme": theme,
        "rendering":
          "PasswordManagerSettingsView in un-ordered NSHostingView via PDFKit rasterization",
      ])
    }

    let manifest: [String: Any] = [
      "componentOnly": true,
      "desktopActivation": false,
      "physicalInput": false,
      "screenCapture": false,
      "command":
        "ARCUSIS_NATIVE_SETTINGS_CAPTURE=1 ARCUSIS_NATIVE_BITWARDEN_SDK=1 swift test --jobs 2 --scratch-path build/Verification/native-bitwarden-sdk-tests --manifest-cache none --filter PasswordManagerSettingsTests",
      "sdkAvailabilitySource": "compiled NativeBitwardenController.sdkAvailable",
      "syntheticChallengeCapture": true,
      "visualAcceptance": false,
      "captureLimitation":
        "Un-ordered NSHostingView bitmap and PDF rendering omit SwiftUI labels, buttons, and status text; captures are incomplete.",
      "captures": captures,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    #expect(captures.count == 6)
    #expect(captures.allSatisfy { ($0["width"] as? Int ?? 0) > 0 })
  }

  @Test func nativeVaultSettingsStartOffAndUnavailableBackendReportsBoundary() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let controller = NativeBitwardenController(
      preferences: preferences, backend: UnavailableTestBackend())
    controller.selectProfile(profile)
    #expect(!controller.isEnabled)
    #expect(controller.status == "Off")
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<100 where controller.isLoading {
      await Task.yield()
    }
    #expect(controller.status == "Native Bitwarden is unavailable in this build.")
    controller.closeSettings()
    #expect(controller.masterPassword.isEmpty)
  }

  @Test func customBasePathChangeCreatesDistinctVaultIdentity() {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let initial = preferences.nativeVaultPreferences(for: profile)
    let first = BitwardenServerConfiguration(
      region: .custom, customBaseURL: "https://vault.example.test/team-a")
    preferences.setNativeVaultServer(first, for: profile)
    let firstID = preferences.nativeVaultPreferences(for: profile).vaultID
    let second = BitwardenServerConfiguration(
      region: .custom, customBaseURL: "https://vault.example.test/team-b")
    preferences.setNativeVaultServer(second, for: profile)
    let changed = preferences.nativeVaultPreferences(for: profile)
    #expect(firstID != changed.vaultID)
    #expect(changed.accountID == nil)
    #expect(initial.vaultID != changed.vaultID)
  }
}

private struct UnavailableTestBackend: NativeBitwardenBackend {
  var isAvailable: Bool { get async { false } }

  func login(
    server: BitwardenServerConfiguration, email: String, password: String,
    deviceID: UUID, secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult {
    throw NativeBitwardenBackendError.sdkUnavailable
  }

  func initializeCrypto(candidateID: UUID, password: String) async throws
    -> NativeBitwardenEstablishedSession
  { throw NativeBitwardenBackendError.sdkUnavailable }

  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot { .empty }
  func lock(sessionID: UUID) async -> Bool { false }
  func discard(sessionID: UUID) async {}
}

private struct SyntheticChallengeBackend: NativeBitwardenBackend {
  var isAvailable: Bool { get async { true } }

  func login(
    server: BitwardenServerConfiguration, email: String, password: String,
    deviceID: UUID, secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult {
    .challenge(UUID(), [.authenticator, .email])
  }

  func initializeCrypto(candidateID: UUID, password: String) async throws
    -> NativeBitwardenEstablishedSession
  { throw NativeBitwardenBackendError.candidateUnavailable }

  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot { .empty }
  func lock(sessionID: UUID) async -> Bool { false }
  func discard(sessionID: UUID) async {}
}

@MainActor
private func renderNativeSettings(
  controller: NativeBitwardenController, colorScheme: ColorScheme, to url: URL
) async throws -> (width: Int, height: Int) {
  let size = NSSize(width: 720, height: 480)
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
  let hostingView = NSHostingView(
    rootView: PasswordManagerSettingsView(controller: controller)
      .environment(\.colorScheme, colorScheme))
  hostingView.appearance = window.appearance
  hostingView.frame = NSRect(origin: .zero, size: size)
  window.contentView = hostingView
  try await Task.sleep(for: .milliseconds(120))
  window.displayIfNeeded()
  hostingView.layoutSubtreeIfNeeded()

  let pdfData = hostingView.dataWithPDF(inside: hostingView.bounds)
  guard let document = PDFDocument(data: pdfData), let page = document.page(at: 0) else {
    throw NativeSettingsRenderError.pdfUnavailable
  }
  let image = page.thumbnail(of: size, for: .mediaBox)
  guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    throw NativeSettingsRenderError.bitmapUnavailable
  }
  let bitmap = NSBitmapImageRep(cgImage: cgImage)
  guard let bitmapData = bitmap.bitmapData else { throw NativeSettingsRenderError.emptyImage }
  let sampledColors: [UInt32] = stride(
    from: 0, to: bitmap.pixelsWide * bitmap.pixelsHigh, by: 8
  ).compactMap { index in
    let offset =
      (index / bitmap.pixelsWide) * bitmap.bytesPerRow
      + (index % bitmap.pixelsWide) * bitmap.bitsPerPixel / 8
    guard offset + 3 < bitmap.bytesPerRow * bitmap.pixelsHigh,
      bitmapData[offset + 3] > 0
    else { return nil }
    return UInt32(bitmapData[offset]) << 16 | UInt32(bitmapData[offset + 1]) << 8
      | UInt32(bitmapData[offset + 2])
  }
  let colors = Set<UInt32>(sampledColors)
  guard colors.count > 8,
    let png = bitmap.representation(using: .png, properties: [:]), png.count > 1_000
  else { throw NativeSettingsRenderError.emptyImage }
  try png.write(to: url, options: .atomic)
  window.close()
  return (bitmap.pixelsWide, bitmap.pixelsHigh)
}

private enum NativeSettingsRenderError: Error {
  case pdfUnavailable
  case bitmapUnavailable
  case emptyImage
}
