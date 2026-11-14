// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test @MainActor func libraryPanelShowsStaleProfileStateAfterSpaceSwitch() throws {
  var session = BrowserSession.fresh()
  let originalProfileID = session.selectedSpace.profileID
  let otherSpace = try #require(session.spaces.first { $0.profileID != originalProfileID })
  session.selectSpace(otherSpace.id)
  let store = BrowserStore(session: session)
  let view = LibraryPanel(
    store: store, profileID: originalProfileID, section: .bookmarks)
  let imageURL = FileManager.default.temporaryDirectory.appending(
    path: "library-panel-profile-(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: imageURL) }

  _ = try VisualCapture.renderOffscreen(
    view, size: NSSize(width: 600, height: 480), appearance: .aqua, to: imageURL)
  let visibleText = try VisualTextRecognition.lines(in: imageURL).joined(separator: " ")
  #expect(visibleText.contains("Profile changed"), "\(visibleText)")
}
