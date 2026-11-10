// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

@testable import ArcusisBrowser

struct ShaarViewportFixtureClick: Equatable {
  let viewportID: UUID
  let x: Int
  let y: Int
}

@MainActor final class ShaarViewportsFixtureTransport: ShaarViewportsTransport {
  private(set) var frames: [ShaarViewportFrame]
  private(set) var clicks: [ShaarViewportFixtureClick] = []
  private(set) var hovers: [ShaarViewportFixtureClick] = []
  private(set) var typed: [String] = []
  private(set) var scrolls: [UUID: (Int, Int)] = [:]
  private(set) var targets: [SiteControlTarget] = []
  private var continuation: AsyncStream<ShaarViewportsMessage>.Continuation?
  private var streamID = 0
  private var mirroredScheme: ShaarViewportColorScheme?
  private let capabilities: ShaarViewportCapabilities

  init(
    frames: [ShaarViewportFrame],
    capabilities: ShaarViewportCapabilities = .supported
  ) {
    self.frames = frames
    self.capabilities = capabilities
  }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarViewportsMessage> {
    streamID += 1
    let streamID = streamID
    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.yield(.capabilities(capabilities))
      continuation.yield(.available)
      continuation.yield(.frames(frames))
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor in
          guard self?.streamID == streamID else { return }
          self?.continuation = nil
        }
      }
    }
  }

  func perform(_ action: ShaarViewportAction, for target: SiteControlTarget) async throws {
    targets.append(target)
    switch action {
    case .add(let preset):
      guard frames.count < 4, let url = frames.first?.url else {
        throw ShaarViewportsError.invalidAction
      }
      frames.append(
        ShaarViewportFrame(
          id: UUID(), preset: preset, url: url, pngData: Data(),
          safeArea: preset.defaultInsets, colorScheme: mirroredScheme ?? .noPreference))
    case .remove(let id):
      guard frames.count > 1, frames.contains(where: { $0.id == id }) else {
        throw ShaarViewportsError.invalidAction
      }
      frames.removeAll { $0.id == id }
    case .setSafeArea(let id, let insets):
      guard insets.isValid, let index = frames.firstIndex(where: { $0.id == id }) else {
        throw ShaarViewportsError.invalidAction
      }
      frames[index].safeArea = insets
    case .rotate(let id):
      guard let index = frames.firstIndex(where: { $0.id == id }) else {
        throw ShaarViewportsError.invalidAction
      }
      frames[index] = frames[index].rotated(keepingImage: true)
    case .click(let id, let x, let y):
      clicks = try project(id, x: x, y: y)
    case .hover(let id, let x, let y):
      hovers = try project(id, x: x, y: y)
    case .type(let id, let text):
      guard ShaarViewportTyping.isValid(text), frames.contains(where: { $0.id == id }) else {
        throw ShaarViewportsError.invalidAction
      }
      typed.append(text)
    case .setColorScheme(let id, let scheme):
      guard let index = frames.firstIndex(where: { $0.id == id }) else {
        throw ShaarViewportsError.invalidAction
      }
      frames[index].colorScheme = scheme
      mirroredScheme = nil
    case .mirrorColorScheme(let scheme):
      guard !frames.isEmpty else { throw ShaarViewportsError.invalidAction }
      mirroredScheme = scheme
      for index in frames.indices { frames[index].colorScheme = scheme }
    case .scroll(let id, let deltaX, let deltaY):
      guard frames.contains(where: { $0.id == id }) else {
        throw ShaarViewportsError.invalidAction
      }
      scrolls = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, (deltaX, deltaY)) })
    case .navigate(let url):
      frames = frames.map { frame in
        ShaarViewportFrame(
          id: frame.id, preset: frame.preset, url: url, pngData: frame.pngData,
          safeArea: frame.safeArea, orientation: frame.orientation,
          colorScheme: frame.colorScheme)
      }
    }
    continuation?.yield(.frames(frames))
  }

  private func project(_ id: UUID, x: Int, y: Int) throws -> [ShaarViewportFixtureClick] {
    guard let source = frames.first(where: { $0.id == id }) else {
      throw ShaarViewportsError.invalidAction
    }
    return frames.map { frame in
      ShaarViewportFixtureClick(
        viewportID: frame.id,
        x: ShaarViewportGeometry.project(x, from: source.contentWidth, to: frame.contentWidth),
        y: ShaarViewportGeometry.project(y, from: source.contentHeight, to: frame.contentHeight))
    }
  }
}
