// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ShaarVerification

@Suite struct AbruptCheckpointTests {
  @Test func checkpointRequiresActualSavedModelAndNeverRepairsIt() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = SessionFile(url: root.appending(path: "session.json"))
    var session = BrowserSession.fresh()
    try saved.save(session)
    let original = try Data(contentsOf: saved.url)
    session.open(URL(string: "https://example.com/account")!)
    #expect(throws: AbruptCheckpointError.self) {
      try AbruptProbeCheckpoint.record(
        root: root, session: session, checks: ["fixture"], chromiumVersion: "test")
    }
    #expect(try Data(contentsOf: saved.url) == original)
    #expect(
      !FileManager.default.fileExists(
        atPath: root.appending(path: AbruptProbeCheckpoint.readyName).path))
    try saved.save(session)
    try AbruptProbeCheckpoint.record(
      root: root, session: session, checks: ["fixture"], chromiumVersion: "test")
    #expect(try AbruptProbeCheckpoint.expectedSession(root: root) == session)
    let marker =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appending(path: AbruptProbeCheckpoint.readyName)))
      as? [String: Any]
    #expect(marker?["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier)
    #expect(marker?["ready"] as? Bool == true)
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: saved.url)
    #expect(throws: (any Error).self) { try AbruptProbeCheckpoint.expectedSession(root: root) }
    #expect(try Data(contentsOf: saved.url) == corrupt)
  }

  @Test func missingOrChangedSessionCannotBecomeRecoverySuccess() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = SessionFile(url: root.appending(path: "session.json"))
    let expected = BrowserSession.fresh()
    try saved.save(expected)
    try AbruptProbeCheckpoint.record(
      root: root, session: expected, checks: ["fixture"], chromiumVersion: "test")
    try saved.save(.fresh())
    #expect(throws: AbruptCheckpointError.self) {
      try AbruptProbeCheckpoint.expectedSession(root: root)
    }
    try FileManager.default.removeItem(at: saved.url)
    #expect(throws: AbruptCheckpointError.self) {
      try AbruptProbeCheckpoint.expectedSession(root: root)
    }
    #expect(!FileManager.default.fileExists(atPath: saved.url.path))
  }

  @Test func navigationComparisonAllowsNewTitlesButPreservesOwnershipAndPlacement() throws {
    var expected = BrowserSession.fresh()
    let opened = expected.open(URL(string: "https://example.com/account")!)
    let id = try #require(opened)
    var navigated = expected
    navigated.updateTab(
      id, url: URL(string: "https://example.com/account")!, title: "New page title")
    #expect(AbruptProbeCheckpoint.matchesAfterNavigation(navigated, expected: expected))
    navigated.togglePin(id)
    #expect(!AbruptProbeCheckpoint.matchesAfterNavigation(navigated, expected: expected))
    navigated = expected
    navigated.cycleSpace(by: 1)
    #expect(!AbruptProbeCheckpoint.matchesAfterNavigation(navigated, expected: expected))
    navigated = expected
    navigated.updateTab(id, url: URL(string: "https://other.example.com")!, title: "New page title")
    #expect(!AbruptProbeCheckpoint.matchesAfterNavigation(navigated, expected: expected))
  }
}
