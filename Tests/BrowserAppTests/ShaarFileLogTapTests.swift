// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarFileLogTapTests {
  @Test func selectedViteLogIsTailedOnlyForItsLocalTarget() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "shaar-log-tap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "vite.log")
    try Data("Vite ready\n".utf8).write(to: file)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:5173/")!)
    let model = ShaarDevToolsModel(target: target)
    #expect(model.connectLogTap(file))
    let inspector = InspectorModel(target: target, engine: nil)
    model.open(inspector: inspector)
    for _ in 0..<100 where model.localConsoleEvents.count < 1 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!model.streamAvailable && model.consoleAvailable)
    #expect(model.localConsoleEvents.map(\.message) == ["Vite ready"])
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("Server error\n".utf8))
    try handle.close()
    for _ in 0..<100 where model.localConsoleEvents.count < 2 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.localConsoleEvents.map(\.message) == ["Vite ready", "Server error"])
    model.disconnectLogTap()
    #expect(!model.consoleAvailable && model.localConsoleEvents.isEmpty)
    model.close()
  }

  @Test func remotePageCannotConnectLogTap() throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let model = ShaarDevToolsModel(target: target)
    #expect(!model.connectLogTap(URL(fileURLWithPath: "/tmp/server.log")))
    #expect(!model.hasLogTap)
  }

  @Test func disconnectingFileTapKeepsNextMCPFeed() async throws {
    let server = try LocalConsoleFixtureServer(script: "next_mcp_fixture.py")
    defer { server.stop() }
    let file = FileManager.default.temporaryDirectory
      .appending(path: "shaar-extra-log-\(UUID().uuidString).log")
    try Data("extra server line\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1:\(server.port)/")!)
    let model = ShaarDevToolsModel(
      target: target, localTransports: [ShaarNextMCPConsoleTransport()])
    #expect(model.connectLogTap(file))
    let inspector = InspectorModel(target: target, engine: nil)
    model.open(inspector: inspector)
    for _ in 0..<100 where model.localConsoleEvents.count < 3 {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(model.localAvailableSources == ["nextMCP", "fileLogTap"])
    model.disconnectLogTap()
    #expect(model.consoleAvailable)
    #expect(model.localConsoleEvents.map(\.message).contains("ready on 3000"))
    #expect(!model.localConsoleEvents.map(\.message).contains("extra server line"))
    model.close()
  }
}
