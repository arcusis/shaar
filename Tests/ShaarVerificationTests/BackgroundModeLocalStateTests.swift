// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge.Verification
import Foundation
import Testing

@Suite struct BackgroundModeLocalStateTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "arcusis-local-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func localState(in directory: URL) -> URL {
    directory.appending(path: "Local State")
  }

  private func read(_ directory: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: localState(in: directory))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func backgroundMode(_ state: [String: Any]) -> [String: Any]? {
    state["background_mode"] as? [String: Any]
  }

  @Test func createsOwnerOnlyLocalStateWhenChromiumHasNotRunYet() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let userData = root.appending(path: "Chromium", directoryHint: .isDirectory)

    #expect(ARCDisableBackgroundMode(userData))

    #expect(backgroundMode(try read(userData))?["enabled"] as? Bool == false)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: localState(in: userData).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func turnsBackgroundModeOffAndKeepsEveryOtherPreference() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing: [String: Any] = [
      "browser": ["enabled_labs_experiments": ["probe@1"]],
      "background_mode": ["enabled": true, "other": 7],
    ]
    try JSONSerialization.data(withJSONObject: existing).write(to: localState(in: root))

    #expect(ARCDisableBackgroundMode(root))

    let state = try read(root)
    #expect(backgroundMode(state)?["enabled"] as? Bool == false)
    #expect(backgroundMode(state)?["other"] as? Int == 7)
    let browser = state["browser"] as? [String: Any]
    #expect(browser?["enabled_labs_experiments"] as? [String] == ["probe@1"])
  }

  @Test func leavesLocalStateUntouchedWhenBackgroundModeIsAlreadyOff() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = Data(#"{"background_mode": {"enabled": false}, "keep": 1.0}"#.utf8)
    try original.write(to: localState(in: root))

    #expect(ARCDisableBackgroundMode(root))

    #expect(try Data(contentsOf: localState(in: root)) == original)
  }

  @Test func neverReplacesUnreadableLocalState() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let corrupt = Data("{not json".utf8)
    try corrupt.write(to: localState(in: root))

    #expect(!ARCDisableBackgroundMode(root))

    #expect(try Data(contentsOf: localState(in: root)) == corrupt)
  }
}
