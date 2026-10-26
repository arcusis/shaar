import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Synchronization
import Testing
import Vision

@testable import ArcusisBrowser
@testable import BrowserCore

@Suite @MainActor
struct NativeBitwardenSettingsVisualTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        && ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_SETTINGS_VISUAL_CI"] == "1",
      "Native component capture runs only in explicitly enabled GitHub Actions CI."))
  func capturesSettingsStatesAndRequiresVisibleSwiftUIText() async throws {
    _ = NSApplication.shared
    let outputDirectory = URL(
      fileURLWithPath: "build/Verification/native-settings-visual-ci", isDirectory: true)
    try FileManager.default.createDirectory(
      at: outputDirectory, withIntermediateDirectories: true)

    var captures: [[String: Any]] = []
    var failures: [String] = []
    for appearance in [ColorScheme.light, .dark] {
      for state in [CaptureState.off, .enabled, .customServer] {
        let profileID = UUID()
        let preferences = BrowserPreferencesStore()
        let controller = NativeBitwardenController(
          preferences: preferences,
          credentialStore: PasswordCredentialStore(
            service: "native-settings-visual-\(profileID.uuidString)",
            storage: InMemoryCredentialItems()))
        controller.selectProfile(profileID)
        if state != .off { controller.setEnabled(true) }
        if state == .customServer {
          controller.setServer(
            BitwardenServerConfiguration(
              region: .custom, customBaseURL: "https://vault.example.test/team"))
        }

        let appearanceName = appearance == .dark ? "dark" : "light"
        let filename = "settings-\(state.rawValue)-\(appearanceName).png"
        let imageURL = outputDirectory.appendingPathComponent(filename)
        var recognized: [String] = []
        var pixelSize = (width: 0, height: 0)
        do {
          pixelSize = try await captureOwnedWindow(
            controller: controller, appearance: appearance, to: imageURL)
          recognized = try recognizeText(in: imageURL)
          let visibleText = recognized.joined(separator: " ")
          guard visibleText.contains("Native Bitwarden"),
            visibleText.contains(
              "Vault sessions belong to this Profile and are shared by its Spaces.")
          else { throw NativeSettingsCaptureError.requiredTextMissing }
          if !controller.sdkAvailable, state == .enabled,
            !visibleText.contains("Native Bitwarden is unavailable in this build.")
          {
            throw NativeSettingsCaptureError.requiredTextMissing
          }
          if state == .customServer,
            !visibleText.contains("Enter the HTTPS service base URL.")
              || !visibleText.contains("Apply")
          {
            throw NativeSettingsCaptureError.requiredTextMissing
          }
        } catch {
          failures.append("\(filename): \(error)")
        }
        captures.append([
          "file": filename,
          "width": pixelSize.width,
          "height": pixelSize.height,
          "pointWidth": 720,
          "pointHeight": 480,
          "profile": profileID.uuidString.lowercased(),
          "state": state.rawValue,
          "sdkAvailable": controller.sdkAvailable,
          "status": controller.status,
          "colorScheme": appearanceName,
          "visibleText": recognized,
          "captureMethod": "ordered owned NSWindow; NSView cacheDisplay bitmap; Vision OCR",
        ])
      }
    }

    let manifest: [String: Any] = [
      "componentOnly": true,
      "desktopActivation": false,
      "physicalInput": false,
      "screenCapturePermission": false,
      "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unavailable",
      "sdkAvailabilitySource": "compiled NativeBitwardenController.sdkAvailable",
      "visualAcceptance": false,
      "captures": captures,
      "failures": failures,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    #expect(captures.count == 6)
    #expect(failures.isEmpty, "Visual capture/OCR failures: \(failures)")
  }
}

private enum CaptureState: String {
  case off
  case enabled
  case customServer = "custom-server"
}

@MainActor
private func captureOwnedWindow(
  controller: NativeBitwardenController, appearance: ColorScheme, to url: URL
) async throws -> (width: Int, height: Int) {
  let size = NSSize(width: 720, height: 480)
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
  let view = NSHostingView(
    rootView: PasswordManagerSettingsView(controller: controller)
      .environment(\.colorScheme, appearance))
  view.appearance = window.appearance
  view.frame = NSRect(origin: .zero, size: size)
  window.contentView = view
  window.orderFrontRegardless()

  let deadline = ContinuousClock.now + .seconds(5)
  let minimumSettle = ContinuousClock.now + .milliseconds(250)
  var settledFrames = 0
  while ContinuousClock.now < deadline, settledFrames < 3 {
    window.displayIfNeeded()
    view.layoutSubtreeIfNeeded()
    if view.window === window, view.bounds.width >= 700, view.bounds.height >= 450,
      !view.subviews.isEmpty, ContinuousClock.now >= minimumSettle
    {
      settledFrames += 1
    } else {
      settledFrames = 0
    }
    try await Task.sleep(for: .milliseconds(16))
  }
  guard settledFrames == 3 else { throw NativeSettingsCaptureError.layoutTimeout }
  guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    throw NativeSettingsCaptureError.bitmapUnavailable
  }
  view.cacheDisplay(in: view.bounds, to: bitmap)
  guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 1_000 else {
    throw NativeSettingsCaptureError.emptyImage
  }
  try png.write(to: url, options: .atomic)
  return (bitmap.pixelsWide, bitmap.pixelsHigh)
}

private func recognizeText(in url: URL) throws -> [String] {
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["en-US"]
  try VNImageRequestHandler(url: url).perform([request])
  return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

private final class InMemoryCredentialItems: PasswordCredentialItemStorage, Sendable {
  private let values = Mutex<[String: Data]>([:])

  private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

  func read(service: String, account: String) throws -> Data? {
    values.withLock { $0[key(service, account)] }
  }

  func write(_ data: Data, service: String, account: String) throws {
    values.withLock { $0[key(service, account)] = data }
  }

  func delete(service: String, account: String) throws {
    _ = values.withLock { $0.removeValue(forKey: key(service, account)) }
  }
}

private enum NativeSettingsCaptureError: Error {
  case bitmapUnavailable
  case emptyImage
  case requiredTextMissing
  case layoutTimeout
}
