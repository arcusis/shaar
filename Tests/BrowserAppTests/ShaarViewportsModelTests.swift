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
    let phone = ShaarViewportFrame(
      id: UUID(), preset: .iphone15Pro, url: target.url, pngData: Data())
    let desktop = ShaarViewportFrame(
      id: UUID(), preset: .desktop, url: target.url, pngData: Data())
    let transport = ShaarViewportsFixtureTransport(frames: [phone, desktop])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.count != 2 { await Task.yield() }
    #expect(model.available && model.frames.count == 2)

    try await model.perform(.click(phone.id, x: 100, y: 250))
    #expect(
      transport.clicks == [
        .init(viewportID: phone.id, x: 100, y: 250),
        .init(viewportID: desktop.id, x: 325, y: 234),
      ])
    try await model.perform(.scroll(desktop.id, deltaX: 0, deltaY: 120))
    #expect(transport.scrolls[phone.id]?.1 == 120)
    #expect(transport.scrolls[desktop.id]?.1 == 120)
    try await model.perform(.navigate(URL(string: "https://example.com/b")!))
    #expect(transport.frames.allSatisfy { $0.url.absoluteString == "https://example.com/b" })
    #expect(transport.targets.allSatisfy { $0 == target })

    model.updateTarget(
      SiteControlTarget(
        tabID: target.tabID, profileID: target.profileID,
        url: URL(string: "https://example.com/b")!), committed: true)
    #expect(!model.available && model.frames.isEmpty)
    #expect(model.frames.isEmpty)
    model.close()
  }

  @Test func unavailableTransportRejectsActionsAndUnsafeInsets() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let frame = ShaarViewportFrame(
      id: UUID(), preset: .pixel8, url: target.url, pngData: Data())
    let transport = ShaarViewportsFixtureTransport(frames: [frame])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }
    model.close()
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(.click(frame.id, x: 10, y: 10))
    }
    model.open()
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(
        .setSafeArea(frame.id, ShaarViewportInsets(top: 1000, right: 0, bottom: 0, left: 0)))
    }
    #expect(transport.targets.isEmpty)
    model.close()
  }

  @Test func fixtureKeepsAddedDeviceAndInsetsInSync() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let phone = ShaarViewportFrame(
      id: UUID(), preset: .iphone15Pro, url: target.url, pngData: Data())
    let transport = ShaarViewportsFixtureTransport(frames: [phone])
    let model = ShaarViewportsModel(target: target, transport: transport)
    model.open()
    for _ in 0..<30 where model.frames.isEmpty { await Task.yield() }

    try await model.perform(.add(.pixel8))
    for _ in 0..<30 where model.frames.count != 2 { await Task.yield() }
    let pixel = try #require(model.frames.first(where: { $0.preset == .pixel8 }))
    #expect(pixel.url == phone.url)
    #expect(pixel.safeArea == .init(top: 24, right: 0, bottom: 24, left: 0))

    let insets = ShaarViewportInsets(top: 50, right: 3, bottom: 30, left: 4)
    try await model.perform(.setSafeArea(pixel.id, insets))
    for _ in 0..<30 where model.frames.first(where: { $0.id == pixel.id })?.safeArea != insets {
      await Task.yield()
    }
    #expect(model.frames.first(where: { $0.id == pixel.id })?.safeArea == insets)
    try await model.perform(.remove(pixel.id))
    for _ in 0..<30 where model.frames.count != 1 { await Task.yield() }
    #expect(model.frames.map(\.id) == [phone.id])
    model.close()
  }
}
