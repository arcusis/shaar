// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

enum ShaarViewportPreset: String, CaseIterable, Sendable {
  case iphone15Pro
  case pixel8
  case desktop

  var title: String {
    switch self {
    case .iphone15Pro: "iPhone 15 Pro"
    case .pixel8: "Pixel 8"
    case .desktop: "Desktop"
    }
  }

  var width: Int {
    switch self {
    case .iphone15Pro: 393
    case .pixel8: 412
    case .desktop: 1280
    }
  }

  var height: Int {
    switch self {
    case .iphone15Pro: 852
    case .pixel8: 915
    case .desktop: 800
    }
  }

  var defaultInsets: ShaarViewportInsets {
    switch self {
    case .iphone15Pro: ShaarViewportInsets(top: 59, right: 0, bottom: 34, left: 0)
    case .pixel8: ShaarViewportInsets(top: 24, right: 0, bottom: 24, left: 0)
    case .desktop: .zero
    }
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
}

struct ShaarViewportFrame: Equatable, Sendable, Identifiable {
  let id: UUID
  let preset: ShaarViewportPreset
  let url: URL
  let pngData: Data
  var safeArea: ShaarViewportInsets = .zero
}

enum ShaarViewportAction: Equatable, Sendable {
  case add(ShaarViewportPreset)
  case remove(UUID)
  case setSafeArea(UUID, ShaarViewportInsets)
  case click(UUID, x: Int, y: Int)
  case scroll(UUID, deltaX: Int, deltaY: Int)
  case navigate(URL)
}

enum ShaarViewportsMessage: Sendable {
  case available
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
  private(set) var frames: [ShaarViewportFrame] = []
  private(set) var isOpen = false
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
    frames.removeAll()
  }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    generation += 1
    task?.cancel()
    task = nil
    available = false
    frames.removeAll()
    if isOpen { startStream() }
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
    case .click(let id, let x, let y):
      guard let frame = frames.first(where: { $0.id == id }) else { return false }
      return (0..<frame.preset.width).contains(x) && (0..<frame.preset.height).contains(y)
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
    case .unavailable:
      available = false
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
