// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct InspectorReportArchiveTests {
  @Test func nativeProbeRejectsIncompleteOrInvalidReportMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "inspector-report-metadata-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let valid: [String: Any] = [
      "engineVersion": "155.0.fixture", "sensitiveHeadersIncluded": false,
      "viewport": ["width": 390, "height": 844, "devicePixelRatio": 3],
      "activeSimulations": ["device": "phone"],
    ]
    func archive(_ metadata: Any) async throws -> URL {
      try await BugReportArchive.save(
        files: ["metadata.json": JSONSerialization.data(withJSONObject: metadata)], directory: root)
    }
    let file = try await archive(valid)
    #expect(
      try InspectorPageToolsProbe.reportMetadata(file)["engineVersion"] as? String
        == "155.0.fixture")
    for key in ["engineVersion", "activeSimulations", "sensitiveHeadersIncluded"] {
      var incomplete = valid
      incomplete.removeValue(forKey: key)
      let file = try await archive(incomplete)
      #expect(throws: DeveloperModeFailure.self) {
        _ = try InspectorPageToolsProbe.reportMetadata(file)
      }
    }
    for width in [0, -1] {
      var invalid = valid
      invalid["viewport"] = ["width": width, "height": 844, "devicePixelRatio": 3]
      let file = try await archive(invalid)
      #expect(throws: DeveloperModeFailure.self) {
        _ = try InspectorPageToolsProbe.reportMetadata(file)
      }
    }
    let nonObject = try await archive([])
    #expect(throws: DeveloperModeFailure.self) {
      _ = try InspectorPageToolsProbe.reportMetadata(nonObject)
    }
  }

  @Test func nativeProbeReadsActualArchiveMembersAndRejectsCorruption() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "inspector-report-evidence-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = Data("{\"source\":\"fixture\"}".utf8)
    let archive = try await BugReportArchive.save(
      files: ["metadata.json": metadata, "console.json": Data("[]".utf8)], directory: root)
    #expect(try InspectorPageToolsProbe.readZip(archive, member: "metadata.json") == metadata)
    let members = String(
      decoding: try InspectorPageToolsProbe.readZip(archive, member: nil), as: UTF8.self)
    #expect(members.contains("metadata.json") && members.contains("console.json"))
    let corrupt = root.appending(path: "corrupt.zip")
    try Data("invalid archive".utf8).write(to: corrupt)
    #expect(throws: DeveloperModeFailure.self) {
      _ = try InspectorPageToolsProbe.readZip(corrupt, member: "metadata.json")
    }
  }
}
