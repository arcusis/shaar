// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarViewportsModelTests {
  @Test func fixtureSynchronizesInputAndClearsOnTargetChange() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/a")!)
    let transport = ViewportsFixtureTransport()
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    let phone = ShaarViewportFrame(
      id: UUID(), preset: .iphone15Pro, url: target.url, pngData: Data())
    let desktop = ShaarViewportFrame(
      id: UUID(), preset: .desktop, url: target.url, pngData: Data())
    transport.emit(.available)
    transport.emit(.frames([phone, desktop]))
    for _ in 0..<30 where model.frames.count != 2 { await Task.yield() }
    #expect(model.available && model.frames.count == 2)

    try await model.perform(.click(phone.id, x: 100, y: 250))
    try await model.perform(.scroll(desktop.id, deltaX: 0, deltaY: 120))
    try await model.perform(.navigate(URL(string: "https://example.com/b")!))
    #expect(transport.actions.count == 3)
    #expect(transport.targets.allSatisfy { $0 == target })

    model.updateTarget(
      SiteControlTarget(
        tabID: target.tabID, profileID: target.profileID,
        url: URL(string: "https://example.com/b")!), committed: true)
    #expect(!model.available && model.frames.isEmpty)
    transport.emit(.frames([phone, desktop]))
    await Task.yield()
    #expect(model.frames.isEmpty)
    model.close()
  }

  @Test func unavailableTransportRejectsActionsAndUnsafeInsets() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let transport = ViewportsFixtureTransport()
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    let frame = ShaarViewportFrame(
      id: UUID(), preset: .pixel8, url: target.url, pngData: Data())
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(.click(frame.id, x: 10, y: 10))
    }
    transport.emit(.available)
    transport.emit(.frames([frame]))
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(
        .setSafeArea(frame.id, ShaarViewportInsets(top: 1000, right: 0, bottom: 0, left: 0)))
    }
    #expect(transport.actions.isEmpty)
    model.close()
  }
}

@MainActor private final class ViewportsFixtureTransport: ShaarViewportsTransport {
  private var continuation: AsyncStream<ShaarViewportsMessage>.Continuation?
  private(set) var actions: [ShaarViewportAction] = []
  private(set) var targets: [SiteControlTarget] = []

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarViewportsMessage> {
    AsyncStream { continuation in self.continuation = continuation }
  }

  func perform(_ action: ShaarViewportAction, for target: SiteControlTarget) async throws {
    actions.append(action)
    targets.append(target)
  }

  func emit(_ message: ShaarViewportsMessage) { continuation?.yield(message) }
}
