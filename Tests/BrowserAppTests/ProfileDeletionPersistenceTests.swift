// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileDeletionPersistenceTests: XCTestCase {
  func testProfileDirectoryIsRemovedAfterBackendConfirmsDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: root.appending(path: "workspace.json"),
        legacySessionURL: root.appending(path: "legacy.json")))
    let profileID = try XCTUnwrap(workspace.workspace.catalog.profiles.first?.id)
    let destinationID = try XCTUnwrap(
      workspace.workspace.catalog.profiles.first(where: { $0.id != profileID })?.id)
    let profileDirectory = root.appending(path: "Profile \(profileID.uuidString)")
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    let runtime = ProfileDirectoryRuntime(directory: profileDirectory)
    let backend = ProfileSettingsStub()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: BrowserPreferencesStore(), runtime: runtime,
      profileBackend: backend)

    try await state.deleteProfile(profileID, movingSpacesTo: destinationID)

    XCTAssertFalse(FileManager.default.fileExists(atPath: profileDirectory.path))
    XCTAssertFalse(workspace.workspace.catalog.profiles.contains { $0.id == profileID })
    XCTAssertEqual(backend.calls.map(\.0), ["load", "delete"])
  }

  func testProfileDirectoryRemovalIsIdempotentWhenAlreadyRemoved() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.removeItem(at: directory)
    try await ProfileDataDirectoryRemoval.removeIfPresent(at: directory)

    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testProfileDirectoryRemovalAcceptsChromiumRemovingItConcurrently() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await ProfileDataDirectoryRemoval.removeIfPresent(
      at: directory,
      removeItem: { url in
        try FileManager.default.removeItem(at: url)
        throw CocoaError(.fileNoSuchFile)
      })

    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testDirectoryRemovalFailureDoesNotUndoCompletedProfileDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: root.appending(path: "workspace.json"),
        legacySessionURL: root.appending(path: "legacy.json")))
    let profileID = try XCTUnwrap(workspace.workspace.catalog.profiles.first?.id)
    let destinationID = try XCTUnwrap(
      workspace.workspace.catalog.profiles.first(where: { $0.id != profileID })?.id)
    let profileDirectory = root.appending(path: "Profile \(profileID.uuidString)")
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    let preferences = BrowserPreferencesStore()
    preferences.setSearchEngine(.duckDuckGo, for: profileID)
    let backend = ProfileSettingsStub()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences,
      runtime: ProfileDirectoryRuntime(directory: profileDirectory), profileBackend: backend,
      removeProfileDirectory: { _ in throw CocoaError(.fileWriteNoPermission) })

    try await state.deleteProfile(profileID, movingSpacesTo: destinationID)

    XCTAssertFalse(workspace.workspace.catalog.profiles.contains { $0.id == profileID })
    XCTAssertEqual(preferences.searchEngine(for: profileID), .google)
    XCTAssertEqual(backend.calls.map(\.0), ["load", "delete"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: profileDirectory.path))
  }

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

@MainActor
private final class ProfileDirectoryRuntime: ARCShaarRuntime {
  private let directory: URL

  init(directory: URL) {
    self.directory = directory
    super.init()
  }

  override func profileDataDirectory(forProfileID profileID: String) -> URL? {
    directory
  }
}
