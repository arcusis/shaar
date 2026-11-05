// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct WindowFullScreenObserverTests {
  @Test func reusedObserverReportsToItsCurrentBinding() throws {
    final class Flag {
      var value = false
    }
    let old = Flag()
    let current = Flag()
    let hosting = NSHostingView(
      rootView: WindowFullScreenObserver(
        isFullScreen: Binding(get: { old.value }, set: { old.value = $0 })))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let originalView = try #require(observer(in: hosting))

    hosting.rootView = WindowFullScreenObserver(
      isFullScreen: Binding(get: { current.value }, set: { current.value = $0 }))
    hosting.layoutSubtreeIfNeeded()
    let updatedView = try #require(observer(in: hosting))
    #expect(updatedView === originalView)

    updatedView.onChange?(true)
    #expect(current.value)
    #expect(!old.value)
  }

  private func observer(in view: NSView) -> WindowFullScreenObserver.ObserverView? {
    if let observed = view as? WindowFullScreenObserver.ObserverView { return observed }
    for subview in view.subviews {
      if let observed = observer(in: subview) { return observed }
    }
    return nil
  }
}
