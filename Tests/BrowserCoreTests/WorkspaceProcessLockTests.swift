// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func workspaceLockExcludesOtherDescriptorsAndReleasesWithoutDeletingItsFile() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var owner: WorkspaceProcessLock? = try WorkspaceProcessLock(directory: root)
  let path = root.appending(path: "workspace.lock")
  let original = try Data(contentsOf: path)
  #expect(throws: WorkspaceLockError.self) { _ = try WorkspaceProcessLock(directory: root) }
  #expect(try Data(contentsOf: path) == original)
  #expect(owner != nil)
  owner = nil
  let successor = try WorkspaceProcessLock(directory: root)
  withExtendedLifetime(successor) {
    #expect(FileManager.default.fileExists(atPath: path.path))
  }
}

@Test func workspaceLockRejectsSymlinksWithoutTouchingTheirTargets() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let target = root.appending(path: "original")
  let bytes = Data("preserve".utf8)
  try bytes.write(to: target)
  try FileManager.default.createSymbolicLink(
    at: root.appending(path: "workspace.lock"), withDestinationURL: target)
  #expect(throws: (any Error).self) { _ = try WorkspaceProcessLock(directory: root) }
  #expect(try Data(contentsOf: target) == bytes)
}

@Test func geometrySurvivesCatalogProjectionAndOldSnapshotsCanOmitIt() throws {
  var workspace = try BrowserWorkspace(session: .fresh())
  let id = workspace.windows[0].id
  let geometry = WorkspaceWindowGeometry(x: 10, y: 20, width: 900, height: 650)
  try workspace.setGeometry(geometry, for: id)
  let second = try workspace.addWindow(from: id)
  let otherGeometry = WorkspaceWindowGeometry(x: 40, y: 60, width: 1000, height: 700)
  try workspace.setGeometry(otherGeometry, for: second)
  var session = workspace.windows[0].session
  _ = session.updateSpace(session.selectedSpaceID, name: "Renamed", tint: .forest)
  try workspace.updateWindow(id, session: session)
  #expect(workspace.window(id)?.geometry == geometry)
  #expect(workspace.window(second)?.geometry == otherGeometry)
  let before = workspace
  #expect(throws: WorkspaceError.self) {
    try workspace.setGeometry(WorkspaceWindowGeometry(x: 0, y: 0, width: 10, height: 10), for: id)
  }
  #expect(workspace == before)
  var wire = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
  var windows = try #require(wire["windows"] as? [[String: Any]])
  windows[0]["geometry"] = nil
  wire["windows"] = windows
  let decoded = try JSONDecoder().decode(
    BrowserWorkspace.self, from: JSONSerialization.data(withJSONObject: wire))
  #expect(decoded.windows[0].geometry == nil && decoded.windows[0].session == session)
}

@Test func workspaceLockRejectsHardLinkedLockFiles() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let original = root.appending(path: "original")
  try Data().write(to: original)
  try FileManager.default.linkItem(at: original, to: root.appending(path: "workspace.lock"))
  #expect(throws: WorkspaceLockError.invalidFile) {
    _ = try WorkspaceProcessLock(directory: root)
  }
}

@Test func workspaceLockErrorsDescribeTheConflict() {
  #expect(WorkspaceLockError.inUse.errorDescription?.contains(ProductIdentity.name) == true)
  #expect(WorkspaceLockError.invalidFile.errorDescription == "The workspace lock file is invalid.")
}
