// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Suite struct SnapshotFileTests {
  private let root = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString, directoryHint: .isDirectory)

  private var file: SessionFile { SessionFile(url: root.appending(path: "session.json")) }
  private var snapshot: SnapshotFile<BrowserSession> { SnapshotFile(url: file.url) }

  private func session(opening address: String) -> BrowserSession {
    var session = BrowserSession.fresh()
    session.open(URL(string: address)!)
    return session
  }

  /// Decodes as JSON but fails validation: the selected Space does not exist.
  private func invalidSessionData() throws -> Data {
    let data = try JSONEncoder().encode(BrowserSession.fresh())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["selectedSpaceID"] = UUID().uuidString
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func posixPermissions(_ url: URL) throws -> Int {
    try #require(
      FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  private func temporaryFiles() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
  }

  @Test func saveKeepsOwnerOnlyPermissionsAndRotatesThePreviousFileIntoTheBackup() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let first = session(opening: "https://example.com/first")
    let second = session(opening: "https://example.com/second")
    try file.save(first)
    #expect(!FileManager.default.fileExists(atPath: snapshot.backupURL.path))
    try file.save(second)
    #expect(try file.load() == second)
    #expect(try SnapshotFile<BrowserSession>(url: snapshot.backupURL).loadPrimary() == first)
    #expect(try posixPermissions(file.url) == 0o600)
    #expect(try posixPermissions(snapshot.backupURL) == 0o600)
    #expect(try posixPermissions(root) == 0o700)
    #expect(try temporaryFiles().isEmpty)
  }

  @Test func unreadablePrimaryFallsBackToTheBackupAndIsSetAside() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let good = session(opening: "https://example.com/good")
    try file.save(good)
    try file.save(good)
    let damaged = Data("{\"version\":".utf8)
    try damaged.write(to: file.url)
    #expect(try file.load() == good)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
    #expect(try Data(contentsOf: snapshot.damagedURL) == damaged)

    let next = session(opening: "https://example.com/next")
    try file.save(next)
    #expect(try file.load() == next)
    // The damaged file never rotates into the backup.
    #expect(try SnapshotFile<BrowserSession>(url: snapshot.backupURL).loadPrimary() == good)
  }

  @Test func primaryThatFailsValidationFallsBackToTheBackup() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let good = session(opening: "https://example.com/good")
    try file.save(good)
    try file.save(good)
    try invalidSessionData().write(to: file.url)
    #expect(try file.load() == good)
    #expect(FileManager.default.fileExists(atPath: snapshot.damagedURL.path))
  }

  @Test func missingPrimaryRestoresTheBackup() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let good = session(opening: "https://example.com/good")
    try file.save(good)
    try file.save(good)
    try FileManager.default.removeItem(at: file.url)
    #expect(try file.load() == good)
    #expect(!FileManager.default.fileExists(atPath: snapshot.damagedURL.path))
  }

  @Test func damagedPrimaryWithoutAValidBackupThrowsAndLeavesBothFilesUntouched() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try file.save(.fresh())
    let damaged = Data("not json".utf8)
    try damaged.write(to: file.url)
    #expect(throws: (any Error).self) { try file.load() }
    #expect(try Data(contentsOf: file.url) == damaged)

    let damagedBackup = try invalidSessionData()
    try damagedBackup.write(to: snapshot.backupURL)
    #expect(throws: (any Error).self) { try file.load() }
    #expect(try Data(contentsOf: file.url) == damaged)
    #expect(try Data(contentsOf: snapshot.backupURL) == damagedBackup)
    #expect(!FileManager.default.fileExists(atPath: snapshot.damagedURL.path))
  }

  @Test func loadPrimaryNeverFallsBackOrMovesFiles() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try file.save(.fresh())
    try file.save(.fresh())
    let damaged = Data("not json".utf8)
    try damaged.write(to: file.url)
    #expect(throws: (any Error).self) { try file.loadPrimary() }
    #expect(try Data(contentsOf: file.url) == damaged)
  }

  @Test func failedSaveLeavesTheSavedFilesAndNoTemporaryFile() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let good = session(opening: "https://example.com/good")
    try file.save(good)
    let saved = try Data(contentsOf: file.url)
    var invalid = good
    invalid.selectedSpaceID = UUID()
    #expect(throws: (any Error).self) { try file.save(invalid) }
    #expect(try Data(contentsOf: file.url) == saved)

    // A directory in place of the backup makes the rotation fail after the flushed write.
    try FileManager.default.createDirectory(
      at: snapshot.backupURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      at: snapshot.backupURL.appending(path: "occupied"), withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try file.save(.fresh()) }
    #expect(try Data(contentsOf: file.url) == saved)
    #expect(try temporaryFiles().isEmpty)
  }

  @Test func saveRemovesTemporaryFilesLeftByAKilledWriter() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try file.save(.fresh())
    let leftovers = [".session.json.\(UUID().uuidString).tmp", ".session.json.backup.1.tmp"]
    for name in leftovers { try Data("partial".utf8).write(to: root.appending(path: name)) }
    let unrelated = root.appending(path: ".other.json.\(UUID().uuidString).tmp")
    try Data("other writer".utf8).write(to: unrelated)
    try file.save(.fresh())
    #expect(try temporaryFiles() == [unrelated.lastPathComponent])
  }

  @Test func damagedWorkspaceRestoresItsBackupBeforeTheLegacySession() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceFile = WorkspaceFile(
      url: root.appending(path: "workspace.json"), legacySessionURL: file.url)
    let workspace = try BrowserWorkspace(session: session(opening: "https://example.com/window"))
    try workspaceFile.save(workspace)
    try workspaceFile.save(workspace)
    try file.save(session(opening: "https://example.com/legacy"))
    try Data("{".utf8).write(to: workspaceFile.url)
    #expect(try workspaceFile.load() == workspace)
  }
}
