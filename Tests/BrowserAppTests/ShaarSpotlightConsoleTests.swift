// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarSpotlightConsoleTests {
  @Test func sidecarFixtureFeedsLogsAndErrorsWithoutBrowserCapability() async throws {
    let server = try LocalConsoleFixtureServer(script: "spotlight_fixture.py")
    defer { server.stop() }
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:5173/")!)
    let model = ShaarDevToolsModel(
      target: target, localTransports: [ShaarSpotlightConsoleTransport(port: server.port)])
    let inspector = InspectorModel(target: target, engine: nil)
    model.open(inspector: inspector)
    for _ in 0..<100 where model.localConsoleEvents.count < 2 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!model.streamAvailable && model.consoleAvailable)
    #expect(model.localConsoleEvents.map(\.origin) == [.spotlight, .spotlight])
    #expect(model.localConsoleEvents.map(\.message) == ["worker ready", "Query failed"])
    #expect(model.localConsoleEvents.map(\.level) == [.log, .error])
    model.close()
    #expect(model.localConsoleEvents.isEmpty)
  }

  @Test func sidecarTransportRejectsRemotePage() {
    let remote = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let lan = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://192.168.1.8:5173/")!)
    #expect(ShaarSpotlightConsoleTransport.endpoint(for: remote, port: 8969) == nil)
    #expect(ShaarSpotlightConsoleTransport.endpoint(for: lan, port: 8969) == nil)
  }
}
