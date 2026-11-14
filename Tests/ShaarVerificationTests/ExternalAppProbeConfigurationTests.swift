// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import ChromiumBridgeVerification
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

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

  @Test @MainActor func parsedAuditRequiresIntegerCountsAndAJSONBooleanFlag() {
    let valid = ExternalAppConsentProbe.parseAudit([
      "count": 2, "matchingCount": 1, "allUnremembered": true,
    ])
    #expect(valid?.count == 2 && valid?.matchingCount == 1 && valid?.allUnremembered == true)

    for malformed: [String: Any] in [
      ["count": true, "matchingCount": 1, "allUnremembered": true],
      ["count": 2, "matchingCount": false, "allUnremembered": true],
      ["count": 2, "matchingCount": 1, "allUnremembered": 1],
      ["count": 2.0, "matchingCount": 1, "allUnremembered": true],
    ] {
      #expect(ExternalAppConsentProbe.parseAudit(malformed) == nil)
    }
  }

  @Test @MainActor func runIdentityParserRequiresCanonicalUUIDAndIntegerSchema() throws {
    let runID = "C766672E-AB82-4F84-8ED3-2C6D75AEB1D1"
    let valid = try JSONSerialization.data(withJSONObject: ["schema": 1, "runID": runID])
    #expect(ExternalAppConsentProbe.decodeRunID(valid) == runID)

    let booleanSchema = try JSONSerialization.data(
      withJSONObject: ["schema": true, "runID": runID])
    #expect(ExternalAppConsentProbe.decodeRunID(booleanSchema) == nil)

    let lowercaseID = try JSONSerialization.data(
      withJSONObject: ["schema": 1, "runID": runID.lowercased()])
    #expect(ExternalAppConsentProbe.decodeRunID(lowercaseID) == nil)

    let unexpectedKey = try JSONSerialization.data(
      withJSONObject: ["schema": 1, "runID": runID, "privateData": "ignored"])
    #expect(ExternalAppConsentProbe.decodeRunID(unexpectedKey) == nil)
  }
}
