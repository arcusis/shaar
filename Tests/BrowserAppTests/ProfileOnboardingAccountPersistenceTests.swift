// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import XCTest

@testable import ArcusisBrowser

@MainActor
final class ProfileOnboardingAccountPersistenceTests: XCTestCase {
  func testUnwritableWorkspaceDoesNotSaveAccountOrReportProfileCreated() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceURL = root.appending(path: "workspace.json")
    let workspaceFile = WorkspaceFile(
      url: workspaceURL, legacySessionURL: root.appending(path: "legacy.json"))
    let workspace = try BrowserWorkspaceStore(file: workspaceFile)
    let before = workspace.workspace
    let preferences = BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json"))
    let profileID = UUID()
    let draft = ProfileDraft(
      id: profileID, name: "Work", color: .none,
      accounts: [ConnectedAccount(provider: .google, email: "alex@example.test")], spaceID: nil)

    try FileManager.default.removeItem(at: workspaceURL)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(try draft.create(in: workspace, preferences: preferences))
    XCTAssertEqual(workspace.workspace, before)
    XCTAssertTrue(preferences.accounts(for: profileID).isEmpty)
  }

  func testSuccessfulOnboardingPersistsProfileAndAccountAcrossReload() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceFile = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "legacy.json"))
    let workspace = try BrowserWorkspaceStore(file: workspaceFile)
    let preferencesURL = root.appending(path: "preferences.json")
    let preferences = BrowserPreferencesStore(fileURL: preferencesURL)
    let account = ConnectedAccount(provider: .google, email: "alex@example.test")
    let draft = ProfileDraft(
      id: UUID(), name: "Work", color: .none, accounts: [account], spaceID: nil)

    let profileID = try draft.create(in: workspace, preferences: preferences)
    try workspace.flushSaves()

    let restoredWorkspace = try BrowserWorkspaceStore(file: workspaceFile)
    let restoredPreferences = BrowserPreferencesStore(fileURL: preferencesURL)
    XCTAssertNotNil(restoredWorkspace.workspace.catalog.profiles.first { $0.id == profileID })
    XCTAssertEqual(restoredPreferences.accounts(for: profileID), [account])
  }

  func testUnwritableAccountPreferencesDoNotCreateProfile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceFile = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "legacy.json"))
    let workspace = try BrowserWorkspaceStore(file: workspaceFile)
    let before = workspace.workspace
    let preferencesURL = root.appending(path: "preferences.json")
    let preferences = BrowserPreferencesStore(fileURL: preferencesURL)
    preferences.setSidebarInitiallyVisible(false)
    let originalPreferences = try Data(contentsOf: preferencesURL)
    let profileID = UUID()
    let account = ConnectedAccount(provider: .google, email: "alex@example.test")
    let draft = ProfileDraft(
      id: profileID, name: "Work", color: .none, accounts: [account], spaceID: nil)

    try FileManager.default.removeItem(at: preferencesURL)
    try FileManager.default.createDirectory(
      at: preferencesURL, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: preferencesURL)
      try? originalPreferences.write(to: preferencesURL)
    }

    XCTAssertThrowsError(try draft.create(in: workspace, preferences: preferences))
    XCTAssertEqual(workspace.workspace, before)
    XCTAssertTrue(preferences.accounts(for: profileID).isEmpty)

    try FileManager.default.removeItem(at: preferencesURL)
    try originalPreferences.write(to: preferencesURL)
    let reloaded = BrowserPreferencesStore(fileURL: preferencesURL)
    XCTAssertTrue(reloaded.accounts(for: profileID).isEmpty)
    XCTAssertEqual(try workspaceFile.load(), before)
  }
}
