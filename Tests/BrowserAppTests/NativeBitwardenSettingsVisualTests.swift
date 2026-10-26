import AppKit
import BrowserCore
import CoreGraphics
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
    guard isNativeVisualCI else { return }
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
        var capture: NativeSettingsCapture?
        do {
          capture = try await captureOwnedWindow(
            controller: controller, appearance: appearance, to: imageURL)
          recognized = try recognizeText(in: imageURL)
          guard let capture, capture.alpha.translucentPixels == 0,
            capture.alpha.transparentPixels == 0
          else { throw NativeSettingsCaptureError.nonOpaqueImage }
          let visibleText = recognized.joined(separator: " ")
          // Vision can capitalize lowercase glyphs differently across appearances.
          // Require every expected word, while ignoring OCR-only case changes.
          func containsVisibleText(_ required: String) -> Bool {
            visibleText.range(of: required, options: .caseInsensitive) != nil
          }
          guard containsVisibleText("Native Bitwarden"),
            containsVisibleText(
              "Vault sessions belong to this Profile and are shared by its Spaces.")
          else { throw NativeSettingsCaptureError.requiredTextMissing }
          if !controller.sdkAvailable, state == .enabled,
            !containsVisibleText("Native Bitwarden is unavailable in this build.")
          {
            throw NativeSettingsCaptureError.requiredTextMissing
          }
          if state == .customServer,
            !containsVisibleText("Enter the HTTPS service base URL.")
              || !containsVisibleText("Apply")
          {
            throw NativeSettingsCaptureError.requiredTextMissing
          }
        } catch {
          failures.append("\(filename): \(error)")
        }
        captures.append([
          "file": filename,
          "pixelWidth": capture?.pixelWidth ?? 0,
          "pixelHeight": capture?.pixelHeight ?? 0,
          "pointWidth": capture?.pointWidth ?? 0,
          "pointHeight": capture?.pointHeight ?? 0,
          "alpha": capture?.alpha.manifest ?? [:],
          "layoutDiagnostics": capture?.layoutDiagnostics ?? [:],
          "profile": profileID.uuidString.lowercased(),
          "state": state.rawValue,
          "sdkAvailable": controller.sdkAvailable,
          "status": controller.status,
          "colorScheme": appearanceName,
          "visibleText": recognized,
          "captureMethod":
            "owned NSWindow content NSHostingView cacheDisplay bitmap; opaque alpha validation; Vision OCR",
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

  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        && ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_SETTINGS_VISUAL_CI"] == "1",
      "Native component capture runs only in explicitly enabled GitHub Actions CI."))
  func capturesFillPickerOnContrastingPageBackgrounds() async throws {
    guard isNativeVisualCI else { return }
    _ = NSApplication.shared
    let outputDirectory = URL(
      fileURLWithPath: "build/Verification/native-settings-visual-ci/native-fill",
      isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var captures: [[String: Any]] = []
    var failures: [String] = []
    for appearance in [ColorScheme.light, .dark] {
      for page in [FillCaptureBackground.light, .dark] {
        let appearanceName = appearance == .dark ? "dark" : "light"
        let filename = "picker-\(appearanceName)-on-\(page.rawValue).png"
        let imageURL = outputDirectory.appendingPathComponent(filename)
        var capture: NativeSettingsCapture?
        var recognized: [String] = []
        do {
          let coordinator = try makeFillCaptureCoordinator()
          defer { coordinator.cancel() }
          coordinator.request()
          guard coordinator.showingPicker, coordinator.entries.count == 2 else {
            throw NativeSettingsCaptureError.fixtureUnavailable
          }
          capture = try await captureOwnedView(
            rootView: FillCapturePage(coordinator: coordinator, page: page),
            appearance: appearance, to: imageURL)
          recognized = try recognizeText(in: imageURL)
          guard let capture, capture.alpha.translucentPixels == 0,
            capture.alpha.transparentPixels == 0
          else { throw NativeSettingsCaptureError.nonOpaqueImage }
          let visibleText = recognized.joined(separator: " ")
          for required in ["Choose a vault entry", "Example Portal", "Sample Account", "Cancel"] {
            guard visibleText.range(of: required, options: .caseInsensitive) != nil else {
              throw NativeSettingsCaptureError.requiredTextMissing
            }
          }
        } catch {
          failures.append("\(filename): \(error)")
        }
        captures.append([
          "file": filename,
          "pixelWidth": capture?.pixelWidth ?? 0,
          "pixelHeight": capture?.pixelHeight ?? 0,
          "pointWidth": capture?.pointWidth ?? 0,
          "pointHeight": capture?.pointHeight ?? 0,
          "alpha": capture?.alpha.manifest ?? [:],
          "layoutDiagnostics": capture?.layoutDiagnostics ?? [:],
          "colorScheme": appearanceName,
          "pageBackground": page.rawValue,
          "visibleText": recognized,
          "captureMethod":
            "owned NSWindow content NSHostingView cacheDisplay bitmap; opaque alpha validation; Vision OCR",
        ])
      }
    }
    let manifest: [String: Any] = [
      "componentOnly": true,
      "scope": "same-window SwiftUI password fill overlay with synthetic memory-only fixtures",
      "actualChromiumFill": false,
      "keyboardFocusProof": false,
      "providerAcceptance": false,
      "visualAcceptance": false,
      "desktopActivation": false,
      "physicalInput": false,
      "screenCapturePermission": false,
      "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unavailable",
      "captures": captures,
      "failures": failures,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    #expect(captures.count == 4)
    #expect(failures.isEmpty, "Fill component capture/OCR failures: \(failures)")
  }
}

private enum CaptureState: String {
  case off
  case enabled
  case customServer = "custom-server"
}

private struct NativeSettingsCapture {
  let pixelWidth: Int
  let pixelHeight: Int
  let pointWidth: Double
  let pointHeight: Double
  let alpha: NativeSettingsAlphaProof
  let layoutDiagnostics: [String: Double]
}

private struct NativeSettingsAlphaProof {
  let transparentPixels: Int
  let translucentPixels: Int
  let opaquePixels: Int

  var manifest: [String: Int] {
    [
      "transparentPixels": transparentPixels,
      "translucentPixels": translucentPixels,
      "opaquePixels": opaquePixels,
    ]
  }
}

@MainActor
private func captureOwnedWindow(
  controller: NativeBitwardenController, appearance: ColorScheme, to url: URL
) async throws -> NativeSettingsCapture {
  try await captureOwnedView(
    rootView: PasswordManagerSettingsView(controller: controller), appearance: appearance, to: url)
}

@MainActor
private func captureOwnedView<Content: View>(
  rootView: Content, appearance: ColorScheme, to url: URL
) async throws -> NativeSettingsCapture {
  guard isNativeVisualCI else { throw NativeSettingsCaptureError.captureDisabled }
  let size = NSSize(width: 720, height: 480)
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
  window.isOpaque = true
  window.backgroundColor = .windowBackgroundColor
  let view = NSHostingView(
    rootView:
      rootView
      .environment(\.colorScheme, appearance)
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor)))
  view.appearance = window.appearance
  view.frame = NSRect(origin: .zero, size: size)
  view.autoresizingMask = [.width, .height]
  view.wantsLayer = true
  view.layer?.isOpaque = true
  window.effectiveAppearance.performAsCurrentDrawingAppearance {
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }
  window.contentView = view
  window.orderFrontRegardless()

  let deadline = ContinuousClock.now + .seconds(5)
  let minimumSettle = ContinuousClock.now + .milliseconds(250)
  var settledFrames = 0
  while ContinuousClock.now < deadline, settledFrames < 3 {
    window.displayIfNeeded()
    view.layoutSubtreeIfNeeded()
    if view.window === window, window.contentView === view,
      view.bounds.size == size, view.frame.size == size,
      ContinuousClock.now >= minimumSettle
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
  guard let cgImage = bitmap.cgImage else { throw NativeSettingsCaptureError.bitmapUnavailable }
  let alpha = try alphaProof(for: cgImage)
  return NativeSettingsCapture(
    pixelWidth: bitmap.pixelsWide,
    pixelHeight: bitmap.pixelsHigh,
    pointWidth: Double(view.bounds.width),
    pointHeight: Double(view.bounds.height),
    alpha: alpha,
    layoutDiagnostics: [
      "viewFrameWidth": Double(view.frame.width),
      "viewFrameHeight": Double(view.frame.height),
      "viewBoundsWidth": Double(view.bounds.width),
      "viewBoundsHeight": Double(view.bounds.height),
      "viewFittingWidth": Double(view.fittingSize.width),
      "viewFittingHeight": Double(view.fittingSize.height),
      "windowContentWidth": Double(window.contentView?.bounds.width ?? 0),
      "windowContentHeight": Double(window.contentView?.bounds.height ?? 0),
      "settledFrames": Double(settledFrames),
    ])
}

private func alphaProof(for image: CGImage) throws -> NativeSettingsAlphaProof {
  let width = image.width
  let height = image.height
  let bytesPerRow = width * 4
  var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
  let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
    guard
      let context = CGContext(
        data: bytes.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard rendered else { throw NativeSettingsCaptureError.pixelReadFailed }
  var transparentPixels = 0
  var translucentPixels = 0
  var opaquePixels = 0
  for offset in stride(from: 3, to: pixels.count, by: 4) {
    switch pixels[offset] {
    case 0: transparentPixels += 1
    case 255: opaquePixels += 1
    default: translucentPixels += 1
    }
  }
  return NativeSettingsAlphaProof(
    transparentPixels: transparentPixels,
    translucentPixels: translucentPixels,
    opaquePixels: opaquePixels)
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
  case captureDisabled
  case fixtureUnavailable
  case bitmapUnavailable
  case emptyImage
  case requiredTextMissing
  case layoutTimeout
  case nonOpaqueImage
  case pixelReadFailed
}

private var isNativeVisualCI: Bool {
  ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
    && ProcessInfo.processInfo.environment["ARCUSIS_NATIVE_SETTINGS_VISUAL_CI"] == "1"
}

private enum FillCaptureBackground: String {
  case light, dark

  var color: Color {
    self == .light
      ? Color(red: 0.94, green: 0.96, blue: 0.98)
      : Color(red: 0.08, green: 0.11, blue: 0.15)
  }
}

private struct FillCapturePage: View {
  let coordinator: NativePasswordFillCoordinator
  let page: FillCaptureBackground

  var body: some View {
    ZStack(alignment: .top) {
      page.color
      PasswordFillOverlay(coordinator: coordinator)
    }
  }
}

@MainActor private final class FillCaptureForm: PasswordFillForm {
  let owner: PasswordFillBinding
  init(owner: PasswordFillBinding) { self.owner = owner }
  func request(completion: @escaping (PasswordFillContext?) -> Void) {
    completion(
      PasswordFillContext(
        requestID: UUID(), binding: owner, origin: PasswordFillOrigin("https://example.test")!))
  }
  func fill(
    context: PasswordFillContext, username: String, password: String,
    completion: @escaping (Bool) -> Void
  ) {
    completion(false)
  }
  func cancel() {}
}

@MainActor private final class FillCaptureVault: PasswordFillVault {
  let handle: NativeBitwardenController.FillHandle
  init(owner: PasswordFillBinding) throws {
    let first = UUID()
    let second = UUID()
    let snapshot = try NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: first, name: "Example Portal", username: "sample@example.test", uris: [], isLogin: true,
        isOrganization: false),
      .init(
        id: second, name: "Sample Account", username: "reader@example.test", uris: [],
        isLogin: true, isOrganization: false),
    ])
    var state = NativeBitwardenFillAccessState<Int>(sessionID: UUID())
    let ticket = try state.beginSync()
    try state.publish(ticket: ticket, snapshot: snapshot, items: [first: 1, second: 2])
    state.finishSync(ticket)
    handle = .init(
      binding: .init(
        profileID: owner.profileID, vaultID: UUID(), accountID: UUID(),
        authority: URL(string: "https://example.test")!),
      epoch: UUID(), pair: try state.snapshot())
  }
  func fillHandle(profileID: UUID) -> NativeBitwardenController.FillHandle? {
    profileID == handle.binding.profileID ? handle : nil
  }
  func isFillHandleCurrent(_ handle: NativeBitwardenController.FillHandle) -> Bool {
    handle.epoch == self.handle.epoch && handle.binding == self.handle.binding
  }
  func fillCredential(
    handle: NativeBitwardenController.FillHandle, cipherID: UUID, context: PasswordFillContext
  ) async throws -> NativeBitwardenFillCredential {
    throw NativeBitwardenFillError.cipherUnavailable
  }
}

@MainActor private func makeFillCaptureCoordinator() throws -> NativePasswordFillCoordinator {
  let owner = PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID())
  return NativePasswordFillCoordinator(
    form: FillCaptureForm(owner: owner), vault: try FillCaptureVault(owner: owner),
    binding: { owner })
}
