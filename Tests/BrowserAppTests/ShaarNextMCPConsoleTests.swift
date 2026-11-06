// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarNextMCPConsoleTests {
  @Test func nextFixtureServerFeedsConsoleWithoutBrowserCapability() async throws {
    let server = try LocalConsoleFixtureServer(script: "next_mcp_fixture.py")
    defer { server.stop() }
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(),
      url: URL(string: "http://127.0.0.1:\(server.port)/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let model = ShaarDevToolsModel(
      target: target, localTransports: [ShaarNextMCPConsoleTransport()])
    model.open(inspector: inspector)
    for _ in 0..<100 where model.localConsoleEvents.count < 2 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!model.streamAvailable)
    #expect(model.consoleAvailable)
    #expect(model.localConsoleEvents.map(\.origin) == [.server, .server])
    #expect(model.localConsoleEvents.map(\.message).contains("ready on 3000"))
    #expect(model.localConsoleEvents.map(\.message).contains("Build failed"))
    let remote = SiteControlTarget(
      tabID: target.tabID, profileID: target.profileID,
      url: URL(string: "https://example.com/")!)
    model.updateTarget(remote)
    #expect(!model.consoleAvailable)
    #expect(model.localConsoleEvents.isEmpty)
    model.close()
    #expect(model.localConsoleEvents.isEmpty)
  }

  @Test func nextTransportRejectsNonLoopbackTargets() {
    let remote = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://example.com:3000/")!)
    let lan = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://192.168.1.9:3000/")!)
    #expect(ShaarNextMCPConsoleTransport.endpoint(for: remote) == nil)
    #expect(ShaarNextMCPConsoleTransport.endpoint(for: lan) == nil)
  }
}
