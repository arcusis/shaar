// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func workspaceFavoritesAreListedPerProfileAcrossWindows() throws {
  var workspace = try BrowserWorkspace(session: .fresh())
  let first = workspace.windows[0].id
  let second = try workspace.addWindow(from: first)
  let profiles = workspace.windows[0].session.profiles.map(\.id)
  let mail = try workspace.addFavorite(
    windowID: first, profileID: profiles[0], originalURL: URL(string: "https://mail.example")!)
  let docs = try workspace.addFavorite(
    windowID: second, profileID: profiles[1], originalURL: URL(string: "https://docs.example")!)
  #expect(mail != nil && docs != nil)
  #expect(workspace.favorites(for: profiles[0]).map(\.id) == [mail])
  #expect(workspace.favorites(for: profiles[1]).map(\.id) == [docs])
  #expect(workspace.favorites(for: UUID()).isEmpty)
}

@Test func workspaceFavoriteActionsRejectUnknownWindows() throws {
  var workspace = try BrowserWorkspace(session: .fresh())
  let profile = workspace.windows[0].session.profiles[0].id
  let missing = UUID()
  #expect(throws: WorkspaceError.unknownWindow) {
    try workspace.addFavorite(
      windowID: missing, profileID: profile, originalURL: URL(string: "https://mail.example")!)
  }
  #expect(throws: WorkspaceError.unknownWindow) {
    try workspace.openFavorite(windowID: missing, favoriteID: UUID())
  }
  #expect(throws: WorkspaceError.unknownWindow) {
    try workspace.setGeometry(
      WorkspaceWindowGeometry(x: 0, y: 0, width: 900, height: 700), for: missing)
  }
}

@Test func workspaceErrorsExplainWhyAWorkspaceWasRejected() {
  #expect(WorkspaceError.unsupportedVersion.errorDescription?.contains("unsupported") == true)
  #expect(WorkspaceError.invalidState.errorDescription?.contains("ownership") == true)
  #expect(WorkspaceError.unknownWindow.errorDescription?.contains("window") == true)
}

@Test func openingAFavoriteInAWindowSelectsItsPage() throws {
  var workspace = try BrowserWorkspace(session: .fresh())
  let window = workspace.windows[0].id
  let profile = workspace.windows[0].session.profiles[0].id
  let added = try workspace.addFavorite(
    windowID: window, profileID: profile, originalURL: URL(string: "https://mail.example")!)
  let favorite = try #require(added)
  let opened = try workspace.openFavorite(windowID: window, favoriteID: favorite)
  let tab = try #require(opened)
  let session = try #require(workspace.window(window)?.session)
  #expect(session.selectedSpace.selectedFavoriteID == favorite)
  #expect(session.favoritePage(for: favorite)?.tab.id == tab)
  let missing = try workspace.openFavorite(windowID: window, favoriteID: UUID())
  #expect(missing == nil)
}
