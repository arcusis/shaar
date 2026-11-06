// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarViewportsNativeTransportTests {
  @Test func nativeRepliesDriveFramesAndScopedActions() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/start")!)
    let requester = ViewportRequestFixture()
    let model = ShaarViewportsModel(
      target: target, transport: ShaarViewportsNativeTransport(requester: requester))
    model.open()
    for _ in 0..<100
    where model.frames.count != 2
      || model.frames.contains(where: { $0.pngData.isEmpty })
    {
      await Task.yield()
    }
    #expect(model.available)
    #expect(model.frames.map(\.preset) == [.iphone15Pro, .desktop])
    #expect(model.frames.allSatisfy { !$0.pngData.isEmpty })

    let phone = try #require(model.frames.first(where: { $0.preset == .iphone15Pro }))
    try await model.perform(.click(phone.id, x: 100, y: 200))
    #expect(requester.actions.last?["kind"] as? String == "click")
    #expect(requester.actions.last?["viewportID"] as? Int == 1)
    try await model.perform(
      .setSafeArea(
        phone.id, ShaarViewportInsets(top: 60, right: 0, bottom: 34, left: 0)))
    for _ in 0..<100 where model.frames.first(where: { $0.id == phone.id })?.safeArea.top != 60 {
      await Task.yield()
    }
    #expect(model.frames.first(where: { $0.id == phone.id })?.safeArea.top == 60)
    try await model.perform(.navigate(URL(string: "https://example.com/next")!))
    for _ in 0..<100
    where model.frames.contains(where: {
      $0.url.absoluteString != "https://example.com/next"
    }) { await Task.yield() }
    #expect(model.frames.allSatisfy { $0.url.absoluteString == "https://example.com/next" })
    try await model.perform(.add(.pixel8))
    for _ in 0..<100 where model.frames.count != 3 { await Task.yield() }
    #expect(model.frames.allSatisfy { $0.url.absoluteString == "https://example.com/next" })
    model.close()
    for _ in 0..<100 where requester.closedCount == 0 { await Task.yield() }
    #expect(requester.closedCount == 1)
    #expect(requester.targets.allSatisfy { $0 == target })
  }

  @Test func missingNativeCapabilityKeepsPanelUnavailable() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let requester = ViewportRequestFixture()
    requester.rejectOpen = true
    let model = ShaarViewportsModel(
      target: target, transport: ShaarViewportsNativeTransport(requester: requester))
    model.open()
    for _ in 0..<100 where requester.openCount == 0 { await Task.yield() }
    #expect(!model.available && model.frames.isEmpty)
    await #expect(throws: ShaarViewportsError.self) {
      try await model.perform(.add(.pixel8))
    }
    model.close()
  }
}

@MainActor private final class ViewportRequestFixture: ShaarViewportRequesting {
  var rejectOpen = false
  private(set) var openCount = 0
  private(set) var closedCount = 0
  private(set) var targets: [SiteControlTarget] = []
  private(set) var actions: [[String: Any]] = []
  private var nextViewportID = 1
  private var pageURL: URL?
  private let png = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pJkAAAAASUVORK5CYII="
  )!

  func request(
    _ operation: ShaarDevToolsOperation, target: SiteControlTarget, payload: [String: Any]
  ) async throws -> [String: Any] {
    targets.append(target)
    switch operation {
    case .viewportOpen:
      openCount += 1
      if rejectOpen { throw ShaarViewportsError.unavailable }
      pageURL = target.url
      return ["schemaVersion": 1, "leaseID": 7]
    case .viewportAdd:
      defer { nextViewportID += 1 }
      return ["schemaVersion": 1, "viewportID": nextViewportID]
    case .viewportClose:
      closedCount += 1
      return ["schemaVersion": 1]
    case .viewportFrame:
      return [
        "schemaVersion": 1, "viewportID": payload["viewportID"]!,
        "url": pageURL?.absoluteString ?? target.url.absoluteString,
        "data": png.base64EncodedString(),
      ]
    case .viewportAction:
      actions.append(payload)
      if payload["kind"] as? String == "navigate", let address = payload["url"] as? String {
        pageURL = URL(string: address)
      }
      return ["schemaVersion": 1]
    case .viewportRemove:
      return ["schemaVersion": 1]
    default:
      throw ShaarViewportsError.invalidAction
    }
  }
}
