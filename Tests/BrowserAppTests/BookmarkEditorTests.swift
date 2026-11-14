// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test @MainActor func bookmarkEditorShowsWarningAfterProfileSwitch() throws {
  var session = BrowserSession.fresh()
  let originalProfileID = session.selectedSpace.profileID
  let otherSpace = try #require(session.spaces.first { $0.profileID != originalProfileID })
  session.selectSpace(otherSpace.id)
  let store = BrowserStore(session: session)
  let route = BookmarkEditorRoute(profileID: originalProfileID, mode: .newFolder(parent: nil))
  let view = BookmarkEditor(store: store, route: route)
    .frame(width: 460, height: 380)
    .background(Color.white)
    .environment(\.colorScheme, .light)
  let imageURL = FileManager.default.temporaryDirectory.appending(
    path: "bookmark-editor-stale-route-\(UUID().uuidString).png")
  defer { try? FileManager.default.removeItem(at: imageURL) }

  _ = try VisualCapture.renderOffscreen(
    view, size: NSSize(width: 460, height: 380), appearance: .aqua, to: imageURL)
  let visibleText = try VisualTextRecognition.lines(in: imageURL).joined(separator: " ")
  #expect(visibleText.contains("This bookmark context is no longer available"), "\(visibleText)")
}
