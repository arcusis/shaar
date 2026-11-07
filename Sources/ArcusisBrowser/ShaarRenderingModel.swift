// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarRenderingColorScheme: String, CaseIterable, Identifiable {
  case noOverride
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .noOverride: "No override"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var mediaValue: String {
    switch self {
    case .noOverride: ""
    case .light: "light"
    case .dark: "dark"
    }
  }
}

enum ShaarRenderingMotion: String, CaseIterable, Identifiable {
  case noOverride
  case reduce

  var id: String { rawValue }

  var title: String {
    switch self {
    case .noOverride: "No override"
    case .reduce: "Reduce"
    }
  }

  var mediaValue: String {
    switch self {
    case .noOverride: ""
    case .reduce: "reduce"
    }
  }
}

enum ShaarRenderingCSSMedia: String, CaseIterable, Identifiable {
  case noEmulation
  case screen
  case print

  var id: String { rawValue }

  var title: String {
    switch self {
    case .noEmulation: "No emulation"
    case .screen: "Screen"
    case .print: "Print"
    }
  }

  var mediaValue: String {
    switch self {
    case .noEmulation: ""
    case .screen: "screen"
    case .print: "print"
    }
  }
}

struct ShaarRenderingCall: Equatable {
  enum Payload: Equatable {
    case media(media: String, colorScheme: String, reducedMotion: String)
    case enableOverlay
    case paintRects(Bool)
    case layoutShiftRegions(Bool)
    case fpsMeter(Bool)
  }

  var payload: Payload

  var method: String {
    switch payload {
    case .media: "Emulation.setEmulatedMedia"
    case .enableOverlay: "Overlay.enable"
    case .paintRects: "Overlay.setShowPaintRects"
    case .layoutShiftRegions: "Overlay.setShowLayoutShiftRegions"
    case .fpsMeter: "Overlay.setShowFPSCounter"
    }
  }

  var params: [String: Any] {
    switch payload {
    case .media(let media, let colorScheme, let reducedMotion):
      return [
        "media": media,
        "features": [
          ["name": "prefers-color-scheme", "value": colorScheme],
          ["name": "prefers-reduced-motion", "value": reducedMotion],
        ],
      ]
    case .enableOverlay:
      return [:]
    case .paintRects(let shown):
      return ["result": shown]
    case .layoutShiftRegions(let shown):
      return ["result": shown]
    case .fpsMeter(let shown):
      return ["show": shown]
    }
  }
}

enum ShaarRenderingCommands {
  static func calls(
    colorScheme: ShaarRenderingColorScheme,
    motion: ShaarRenderingMotion,
    cssMedia: ShaarRenderingCSSMedia,
    paintRects: Bool,
    layoutShiftRegions: Bool,
    fpsMeter: Bool,
    overlayAvailable: Bool
  ) -> [ShaarRenderingCall] {
    var calls = [
      ShaarRenderingCall(
        payload: .media(
          media: cssMedia.mediaValue,
          colorScheme: colorScheme.mediaValue,
          reducedMotion: motion.mediaValue))
    ]
    guard overlayAvailable else { return calls }
    calls.append(ShaarRenderingCall(payload: .enableOverlay))
    calls.append(ShaarRenderingCall(payload: .paintRects(paintRects)))
    calls.append(ShaarRenderingCall(payload: .layoutShiftRegions(layoutShiftRegions)))
    calls.append(ShaarRenderingCall(payload: .fpsMeter(fpsMeter)))
    return calls
  }
}

enum ShaarRenderingCapability {
  /// The pinned engine rejects overlay commands it has not been built with.
  static func isMissing(_ error: Error) -> Bool {
    let message = error.localizedDescription
    if message.contains("unknown DevTools") { return true }
    if message.contains("not allowed for this capability") { return true }
    if message.contains("This DevTools command is unavailable") { return true }
    // shaar.20 drops the unknown-command reason, so the bridge reports this.
    if message == "DevTools request failed." { return true }
    return false
  }

  static func targetGone(_ error: Error) -> Bool {
    let message = error.localizedDescription
    if message.contains("no longer available") { return true }
    if message.contains("target changed") { return true }
    return false
  }
}

struct ShaarRenderingFailure: LocalizedError {
  var errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

@MainActor
protocol ShaarRenderingTransport: AnyObject {
  /// `true` when the engine accepted the overlay probe, `false` when that
  /// command is missing, and `nil` when the page was not ready to answer.
  func probeOverlay(for target: SiteControlTarget) async -> Bool?
  func send(_ calls: [ShaarRenderingCall], to target: SiteControlTarget) async throws
}

@MainActor
final class ShaarRenderingPendingTransport: ShaarRenderingTransport {
  func probeOverlay(for target: SiteControlTarget) async -> Bool? { nil }

  func send(_ calls: [ShaarRenderingCall], to target: SiteControlTarget) async throws {
    throw ShaarRenderingFailure("Rendering needs a live page.")
  }
}

@MainActor
@Observable
final class ShaarRenderingModel {
  var colorScheme = ShaarRenderingColorScheme.noOverride {
    didSet { publish(colorScheme != oldValue) }
  }
  var motion = ShaarRenderingMotion.noOverride {
    didSet { publish(motion != oldValue) }
  }
  var cssMedia = ShaarRenderingCSSMedia.noEmulation {
    didSet { publish(cssMedia != oldValue) }
  }
  var paintRects = false {
    didSet { publish(paintRects != oldValue) }
  }
  var layoutShiftRegions = false {
    didSet { publish(layoutShiftRegions != oldValue) }
  }
  var fpsMeter = false {
    didSet { publish(fpsMeter != oldValue) }
  }

  private(set) var overlayCommandsAvailable = false
  private(set) var overlayProbeFinished = false
  private(set) var failure: String?
  @ObservationIgnored private(set) var applying = false

  @ObservationIgnored private var target: SiteControlTarget
  @ObservationIgnored private let transport: any ShaarRenderingTransport
  @ObservationIgnored private var revision = 0
  @ObservationIgnored private var hasApplied = false
  @ObservationIgnored private var probeInFlight = false
  @ObservationIgnored private var restoring = false

  init(
    target: SiteControlTarget,
    transport: any ShaarRenderingTransport = ShaarRenderingPendingTransport()
  ) {
    self.target = target
    self.transport = transport
  }

  func prepare() async {
    guard !overlayProbeFinished, !probeInFlight else { return }
    probeInFlight = true
    defer { probeInFlight = false }
    guard let available = await transport.probeOverlay(for: target) else { return }
    overlayCommandsAvailable = available
    overlayProbeFinished = true
    guard hasApplied else { return }
    schedule()
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool) {
    self.target = target
    guard committed, hasApplied else { return }
    schedule()
  }

  func restore() {
    restoring = true
    colorScheme = .noOverride
    motion = .noOverride
    cssMedia = .noEmulation
    paintRects = false
    layoutShiftRegions = false
    fpsMeter = false
    restoring = false
    guard hasApplied else { return }
    schedule()
  }

  func settled() async {
    while applying {
      await Task.yield()
    }
  }

  private func publish(_ changed: Bool) {
    guard changed, !restoring else { return }
    schedule()
  }

  private var hasOverride: Bool {
    if colorScheme != .noOverride { return true }
    if motion != .noOverride { return true }
    if cssMedia != .noEmulation { return true }
    guard overlayCommandsAvailable else { return false }
    if paintRects { return true }
    if layoutShiftRegions { return true }
    if fpsMeter { return true }
    return false
  }

  private func schedule() {
    revision += 1
    guard !applying else { return }
    applying = true
    Task { await drain() }
  }

  private func drain() async {
    defer { applying = false }
    var completed = -1
    while completed != revision {
      let current = revision
      let calls = ShaarRenderingCommands.calls(
        colorScheme: colorScheme, motion: motion, cssMedia: cssMedia,
        paintRects: paintRects, layoutShiftRegions: layoutShiftRegions,
        fpsMeter: fpsMeter, overlayAvailable: overlayCommandsAvailable)
      let destination = target
      let active = hasOverride
      do {
        try await transport.send(calls, to: destination)
        if current == revision && destination == target {
          hasApplied = active
          failure = nil
        }
      } catch {
        if current == revision { failure = error.localizedDescription }
      }
      completed = current
    }
  }
}
