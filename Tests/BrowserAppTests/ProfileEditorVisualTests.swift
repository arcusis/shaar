// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

/// Captures the Space editor and the Settings profile editor side by side, since both use the
/// same icon and color pickers.
@MainActor
final class ProfileEditorVisualTests: XCTestCase {
  private let output = URL(filePath: "/tmp/shaar-profile-editor")
  private let schemes: [(name: String, appearance: NSAppearance.Name)] = [
    ("light", .aqua), ("dark", .darkAqua),
  ]

  override func setUpWithError() throws {
    try super.setUpWithError()
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  }

  func testSpaceEditorRendersInLightAndDark() throws {
    let session = BrowserSession.fresh()
    let store = BrowserStore(sessionFile: nil, session: session)
    for scheme in schemes {
      let url = output.appending(path: "space-editor-\(scheme.name).png")
      try VisualCapture.renderOffscreen(
        SpaceEditor(store: store, route: .edit(session.selectedSpaceID)),
        size: NSSize(width: 404, height: 520), appearance: scheme.appearance, to: url)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    XCTAssertEqual(store.session, session)
  }

  func testSettingsProfileEditorRendersInLightAndDark() throws {
    let workID = UUID()
    let profiles = [
      BrowserSettingsProfile(
        id: UUID(), name: "Personal", color: ProfileColorChoice(tint: .rose), symbol: "house.fill",
        spaces: [BrowserSettingsSpace(id: UUID(), name: "Home", symbol: "house")]),
      BrowserSettingsProfile(
        id: workID, name: "Acme Work", color: ProfileColorChoice(tint: .ocean),
        symbol: "briefcase.fill",
        spaces: [BrowserSettingsSpace(id: UUID(), name: "Research", symbol: "book")],
        accounts: [
          ConnectedAccount(provider: .google, email: "alex@acme.test", name: "Alex Example")
        ]),
      BrowserSettingsProfile(id: UUID(), name: "Uncolored", spaces: []),
    ]
    for scheme in schemes {
      let view = BrowserSettingsView(
        profiles: profiles, searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
        selectedProfileID: .constant(workID), sidebarInitiallyVisible: .constant(true),
        selectedSearchEngine: .constant("google"), initialSection: .profiles)
      let url = output.appending(path: "settings-profile-editor-\(scheme.name).png")
      try VisualCapture.renderOffscreen(
        view, size: NSSize(width: 720, height: 760), appearance: scheme.appearance, to: url)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
  }
}
