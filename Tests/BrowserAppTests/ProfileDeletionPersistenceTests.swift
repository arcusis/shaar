// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileDeletionPersistenceTests: XCTestCase {
  func testWorkspaceWriteFailureDoesNotStartProfileDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "legacy.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    try workspace.flushSaves()
    let original = try Data(contentsOf: file.url)
    let before = workspace.workspace
    let profileID = try XCTUnwrap(before.catalog.profiles.first?.id)

    try FileManager.default.removeItem(at: file.url)
    try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: file.url)
      try? original.write(to: file.url)
    }

    let backend = ProfileSettingsStub()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: BrowserPreferencesStore(), profileBackend: backend)
    do {
      try await state.deleteProfile(profileID, movingSpacesTo: before.catalog.profiles.last?.id)
      XCTFail("Deletion must fail when the workspace cannot be persisted")
    } catch {}

    XCTAssertEqual(workspace.workspace, before)
    XCTAssertFalse(backend.calls.contains { $0.0 == "delete" })
    try FileManager.default.removeItem(at: file.url)
    try original.write(to: file.url)
    XCTAssertEqual(try file.load(), before)
  }
}
