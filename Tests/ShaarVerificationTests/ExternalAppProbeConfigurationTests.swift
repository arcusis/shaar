// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge.Verification
import Foundation
import Testing

@Suite struct ExternalAppProbeConfigurationTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arcusis-engine-probe-\(UUID().uuidString)"
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let marker = root.appending(path: ".arcusis-probe")
    try Data("arcusis-engine-probe-v1\n".utf8).write(to: marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    return root
  }

  @Test func auditReturnsOnlyBoundedCountsForOwnedEnabledFixture() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = "mailto:probe@example.invalid"
    let result = ARCProbeExternalAppLaunchAuditForTesting(
      target,
      [
        ["url": target, "remembered": false],
        ["url": "https://example.invalid/", "remembered": false],
      ], root, true)

    #expect(result?["count"] as? Int == 2)
    #expect(result?["matchingCount"] as? Int == 1)
    #expect(result?["allUnremembered"] as? Bool == true)
    #expect(
      Set(result?.keys.compactMap { $0 as? String } ?? []) == [
        "count", "matchingCount", "allUnremembered",
      ])
  }

  @Test func auditRejectsDisabledMalformedRememberedAndOversizedInputs() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = "mailto:probe@example.invalid"
    let valid: [[String: Any]] = [["url": target, "remembered": false]]

    #expect(ARCProbeExternalAppLaunchAuditForTesting(target, valid, root, false) == nil)
    #expect(ARCProbeExternalAppLaunchAuditForTesting("missing-scheme", valid, root, true) == nil)
    #expect(
      ARCProbeExternalAppLaunchAuditForTesting(
        target, [["url": target, "remembered": 0]], root, true) == nil)
    #expect(
      ARCProbeExternalAppLaunchAuditForTesting(
        target, [["url": target, "remembered": false, "extra": "private"]], root, true) == nil)
    #expect(
      ARCProbeExternalAppLaunchAuditForTesting(
        target, Array(repeating: ["url": target, "remembered": false], count: 257), root, true)
        == nil)
  }

  @Test func auditRejectsRememberedEntryAndUnmarkedRoot() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = "mailto:probe@example.invalid"
    let remembered = ARCProbeExternalAppLaunchAuditForTesting(
      target, [["url": target, "remembered": true]], root, true)
    #expect(remembered?["allUnremembered"] as? Bool == false)

    let unmarked = root.appending(path: "unmarked")
    try FileManager.default.createDirectory(
      at: unmarked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(
      ARCProbeExternalAppLaunchAuditForTesting(
        target, [["url": target, "remembered": false]], unmarked, true) == nil)
  }
}
