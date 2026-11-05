// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test @MainActor func spacesLibraryDrawerProvidesEditableSearchField() {
  let store = BrowserStore()
  #expect(store.showLibraryDrawer(.spaces))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
    styleMask: [], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let host = NSHostingView(rootView: BrowserLibraryDrawer(store: store))
  window.contentView = host
  host.frame = window.contentView!.bounds
  host.layoutSubtreeIfNeeded()
  window.displayIfNeeded()

  func editableFields(in view: NSView) -> [NSTextField] {
    let current = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
    return current + view.subviews.flatMap(editableFields)
  }

  let fields = editableFields(in: host)
  #expect(fields.count == 1)
  #expect(fields.first?.placeholderString == PanelsL10n.string("Search Spaces…"))
}
