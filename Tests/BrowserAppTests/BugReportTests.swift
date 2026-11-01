// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func harRedactsSensitiveHeaderNamesInBothDirections() throws {
  let values: [[String: Any]] = [
    ["name": "AUTHORIZATION", "value": "fixture-secret"],
    ["name": "Cookie", "value": "session=fixture-secret"],
    ["name": "Set-Cookie", "value": "session=fixture-secret"],
    ["name": "Proxy-Authorization", "value": "fixture-secret"],
    ["name": "X-Fixture", "value": "kept"],
  ]
  let snapshot: [String: Any] = [
    "timeOrigin": 1_700_000_000_000.0,
    "network": [
      [
        "url": "http://report.localhost/data", "method": "POST", "start": 1.0,
        "end": 3.0, "status": 200, "headers": values, "responseHeaders": values,
      ]
    ],
    "resources": [["url": "http://report.localhost/data", "start": 1.0, "duration": 2.0]],
  ]
  let redacted = try JSONSerialization.data(
    withJSONObject: BugReportArchive.har(
      snapshot: snapshot, includeSensitiveHeaders: false, version: "test"))
  let included = try JSONSerialization.data(
    withJSONObject: BugReportArchive.har(
      snapshot: snapshot, includeSensitiveHeaders: true, version: "test"))
  #expect(!String(decoding: redacted, as: UTF8.self).contains("fixture-secret"))
  #expect(String(decoding: redacted, as: UTF8.self).contains("kept"))
  #expect(String(decoding: included, as: UTF8.self).contains("fixture-secret"))
}

@MainActor @Test func generatedReportSurvivesEngineHistoryRefreshAndStaysProfileScoped() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "report.zip")
  try Data("report".utf8).write(to: file)
  let profile = UUID()
  let model = DownloadsModel()
  model.registerGeneratedFile(file, profileID: profile)
  model.restore([], profileID: profile)
  #expect(model.libraryItems(in: profile).first?.filename == "report.zip")
  #expect(model.libraryItems(in: UUID()).isEmpty)
  try FileManager.default.removeItem(at: file)
  #expect(model.libraryItems(in: profile).isEmpty)
}

@Test func reportCreatesSingleZipWithRestrictedPermissions() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = try await BugReportArchive.save(
    files: ["metadata.json": Data("{}".utf8), "network.har": Data("{}".utf8)], directory: root)
  #expect(file.pathExtension == "zip")
  #expect(try Data(contentsOf: file).starts(with: [0x50, 0x4b]))
  #expect(
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
}

@Test func harRejectsNonFiniteTimestampsAndBoundsPageSuppliedStatus() throws {
  let snapshot: [String: Any] = [
    "timeOrigin": Double.infinity,
    "resources": [
      [
        "url": "http://report.localhost/data", "status": Double.greatestFiniteMagnitude,
        "start": Double.infinity,
      ]
    ],
  ]
  let har = BugReportArchive.har(
    snapshot: snapshot, includeSensitiveHeaders: false, version: "test")
  #expect(throws: Never.self) { _ = try JSONSerialization.data(withJSONObject: har) }
}
