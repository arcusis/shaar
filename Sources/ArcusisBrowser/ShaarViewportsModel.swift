// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreGraphics
import Foundation
import Observation

enum ShaarViewportPreset: String, CaseIterable, Sendable {
  case iphone15Pro
  case ipad
  case pixel8
  case desktop
  case desktop1440

  var title: String {
    switch self {
    case .iphone15Pro: "iPhone 15 Pro"
    case .ipad: "iPad"
    case .pixel8: "Pixel 8"
    case .desktop: "Desktop 1280"
    case .desktop1440: "Desktop 1440"
    }
  }

  var width: Int {
    switch self {
    case .iphone15Pro: 393
    case .ipad: 820
    case .pixel8: 412
    case .desktop: 1280
    case .desktop1440: 1440
    }
  }

  var height: Int {
    switch self {
    case .iphone15Pro: 852
    case .ipad: 1180
    case .pixel8: 915
    case .desktop: 800
    case .desktop1440: 900
    }
  }

  var defaultInsets: ShaarViewportInsets {
    switch self {
    case .iphone15Pro: ShaarViewportInsets(top: 59, right: 0, bottom: 34, left: 0)
    case .ipad: ShaarViewportInsets(top: 24, right: 0, bottom: 20, left: 0)
    case .pixel8: ShaarViewportInsets(top: 24, right: 0, bottom: 24, left: 0)
    case .desktop, .desktop1440: .zero
    }
  }
}

enum ShaarViewportOrientation: String, Equatable, Sendable {
  case portrait
  case landscape
}

enum ShaarViewportColorScheme: String, Equatable, Sendable, CaseIterable {
  case noPreference
  case light
  case dark

  var title: String {
    switch self {
    case .noPreference: "Device"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var next: Self {
    switch self {
    case .noPreference: .light
    case .light: .dark
    case .dark: .noPreference
    }
  }
}

struct ShaarViewportCapabilities: Equatable, Sendable {
  var colorScheme = false
  var hover = false
  var typing = false

  static let supported = Self(colorScheme: true, hover: true, typing: true)
}

enum ShaarViewportTyping {
  static let maximumBytes = 64

  static func isValid(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard (1...maximumBytes).contains(bytes.count) else { return false }
    return bytes.allSatisfy { byte in byte >= 0x20 && byte != 0x7F }
  }
}

enum ShaarViewportGeometry {
  static func project(_ value: Int, from source: Int, to destination: Int) -> Int {
    guard source > 0 else { return 0 }
    return value * destination / source
  }
}

enum ShaarViewportPreviewLayout {
  static let cardChrome: CGFloat = 76
  static let cardSpacing: CGFloat = 12
  static let outerPadding: CGFloat = 28
  static let fixedScale: CGFloat = 0.5
  /// Wide enough for the device title and the rotate and remove buttons.
  static let minimumCardWidth: CGFloat = 200

  static func scale(fitting: Bool, content: [CGSize], available: CGSize) -> CGFloat {
    guard fitting else { return fixedScale }
    return fitScale(content: content, available: available)
  }

  static func fitScale(content: [CGSize], available: CGSize) -> CGFloat {
    guard let tallest = content.map(\.height).max(), tallest > 0 else { return fixedScale }
    let widthSum = content.reduce(CGFloat(0)) { partial, size in partial + size.width }
    let gaps = cardSpacing * CGFloat(max(content.count - 1, 0))
    let usableWidth = available.width - outerPadding
    let usableHeight = available.height - outerPadding - cardChrome
    guard usableWidth > 1, usableHeight > 1, widthSum + gaps > 0 else { return fixedScale }
    let widthScale = usableWidth / (widthSum + gaps)
    let heightScale = usableHeight / tallest
    return min(1, widthScale, heightScale)
  }

  static func previewSize(contentWidth: Int, contentHeight: Int, scale: CGFloat) -> CGSize {
    CGSize(
      width: max(1, (CGFloat(contentWidth) * scale).rounded()),
      height: max(1, (CGFloat(contentHeight) * scale).rounded()))
  }

  static func cardWidth(previewWidth: CGFloat) -> CGFloat {
    max(previewWidth, minimumCardWidth)
  }

  static func notchSize(previewWidth: CGFloat) -> CGSize {
    let width = max(12, (previewWidth * 0.25).rounded())
    let height = max(4, (width * 0.204).rounded())
    return CGSize(width: width, height: height)
  }
}

struct ShaarViewportInsets: Equatable, Sendable {
  let top: Int
  let right: Int
  let bottom: Int
  let left: Int

  static let zero = Self(top: 0, right: 0, bottom: 0, left: 0)

  var isValid: Bool {
    [top, right, bottom, left].allSatisfy { (0...200).contains($0) }
  }

  var rotatedClockwise: Self {
    Self(top: left, right: top, bottom: right, left: bottom)
  }

  var rotatedCounterclockwise: Self {
    Self(top: right, right: bottom, bottom: left, left: top)
  }
}

struct ShaarViewportFrame: Equatable, Sendable, Identifiable {
  let id: UUID
  let preset: ShaarViewportPreset
  let url: URL
  let pngData: Data
  var safeArea: ShaarViewportInsets = .zero
  var orientation: ShaarViewportOrientation = .portrait
  var colorScheme: ShaarViewportColorScheme = .noPreference

  var contentWidth: Int {
    orientation == .portrait ? preset.width : preset.height
  }

  var contentHeight: Int {
    orientation == .portrait ? preset.height : preset.width
  }

  func rotated(keepingImage: Bool) -> Self {
    let nextInsets =
      orientation == .portrait ? safeArea.rotatedClockwise : safeArea.rotatedCounterclockwise
    let nextOrientation: ShaarViewportOrientation =
      orientation == .portrait ? .landscape : .portrait
    return Self(
      id: id, preset: preset, url: url, pngData: keepingImage ? pngData : Data(),
      safeArea: nextInsets, orientation: nextOrientation, colorScheme: colorScheme)
  }
}

enum ShaarViewportAction: Equatable, Sendable {
  case add(ShaarViewportPreset)
  case remove(UUID)
  case setSafeArea(UUID, ShaarViewportInsets)
  case rotate(UUID)
  case click(UUID, x: Int, y: Int)
  case hover(UUID, x: Int, y: Int)
  case type(UUID, text: String)
  case setColorScheme(UUID, ShaarViewportColorScheme)
  case mirrorColorScheme(ShaarViewportColorScheme)
  case scroll(UUID, deltaX: Int, deltaY: Int)
  case navigate(URL)
}

enum ShaarViewportsMessage: Sendable {
  case available
  case capabilities(ShaarViewportCapabilities)
  case unavailable
  case frames([ShaarViewportFrame])
}

enum ShaarViewportsError: LocalizedError {
  case unavailable
  case invalidAction
  case staleTarget

  var errorDescription: String? {
    switch self {
    case .unavailable: ShellL10n.string("Live Viewports need engine support")
    case .invalidAction: ShellL10n.string("Invalid viewport action")
    case .staleTarget: ShellL10n.string("Viewport target changed")
    }
  }
}

@MainActor protocol ShaarViewportsTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarViewportsMessage>
  func perform(_ action: ShaarViewportAction, for target: SiteControlTarget) async throws
}

/// The live transport opens only after the native multi-viewport capability is connected.
struct ShaarViewportsPendingTransport: ShaarViewportsTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarViewportsMessage> {
    AsyncStream { continuation in
      continuation.yield(.unavailable)
      continuation.finish()
    }
  }

  func perform(_ action: ShaarViewportAction, for target: SiteControlTarget) async throws {
    throw ShaarViewportsError.unavailable
  }
}

@MainActor @Observable
final class ShaarViewportsModel {
  private(set) var target: SiteControlTarget
  private(set) var available = false
  private(set) var capabilities = ShaarViewportCapabilities()
  private(set) var frames: [ShaarViewportFrame] = []
  private(set) var isOpen = false
  var zoomToFit = true
  @ObservationIgnored private let transport: any ShaarViewportsTransport
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  init(target: SiteControlTarget, transport: any ShaarViewportsTransport) {
    self.target = target
    self.transport = transport
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    startStream()
  }

  func close() {
    generation += 1
    task?.cancel()
    task = nil
    isOpen = false
    available = false
    capabilities = ShaarViewportCapabilities()
    frames.removeAll()
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    generation += 1
    task?.cancel()
    task = nil
    available = false
    capabilities = ShaarViewportCapabilities()
    frames.removeAll()
    if isOpen { startStream() }
  }

  func contactSheetPNG() -> Data? {
    ShaarViewportContactSheet.png(frames: frames)
  }

  func perform(_ action: ShaarViewportAction) async throws {
    guard isOpen, available else { throw ShaarViewportsError.unavailable }
    guard accepts(action) else { throw ShaarViewportsError.invalidAction }
    let target = target
    let generation = generation
    try await transport.perform(action, for: target)
    guard isOpen, available, self.target == target, self.generation == generation else {
      throw ShaarViewportsError.staleTarget
    }
  }

  private func accepts(_ action: ShaarViewportAction) -> Bool {
    switch action {
    case .add:
      return frames.count < 4
    case .remove(let id):
      return frames.count > 1 && frames.contains { $0.id == id }
    case .setSafeArea(let id, let insets):
      return insets.isValid && frames.contains { $0.id == id }
    case .rotate(let id):
      return frames.contains { $0.id == id }
    case .click(let id, let x, let y), .hover(let id, let x, let y):
      guard let frame = frames.first(where: { $0.id == id }) else { return false }
      if case .hover = action, !capabilities.hover { return false }
      return (0..<frame.contentWidth).contains(x) && (0..<frame.contentHeight).contains(y)
    case .type(let id, let text):
      return capabilities.typing && ShaarViewportTyping.isValid(text)
        && frames.contains { $0.id == id }
    case .setColorScheme(let id, _):
      return capabilities.colorScheme && frames.contains { $0.id == id }
    case .mirrorColorScheme:
      return capabilities.colorScheme && !frames.isEmpty
    case .scroll(let id, let deltaX, let deltaY):
      return frames.contains { $0.id == id }
        && (-2_000...2_000).contains(deltaX) && (-2_000...2_000).contains(deltaY)
    case .navigate(let url):
      return ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }
  }

  private func startStream() {
    let target = target
    let generation = generation
    let stream = transport.messages(for: target)
    task = Task { [weak self] in
      for await message in stream {
        guard let self, self.isOpen, self.target == target,
          self.generation == generation
        else { return }
        self.receive(message)
      }
    }
  }

  private func receive(_ message: ShaarViewportsMessage) {
    switch message {
    case .available: available = true
    case .capabilities(let next): capabilities = next
    case .unavailable:
      available = false
      capabilities = ShaarViewportCapabilities()
      frames.removeAll()
    case .frames(let next):
      guard available, (1...4).contains(next.count) else { return }
      guard Set(next.map(\.id)).count == next.count,
        Set(next.map(\.url)).count == 1,
        next.allSatisfy({ $0.safeArea.isValid && $0.pngData.count <= 8 * 1024 * 1024 })
      else { return }
      frames = next
    }
  }

  isolated deinit { task?.cancel() }
}
