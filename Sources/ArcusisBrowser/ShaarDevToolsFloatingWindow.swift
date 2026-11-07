// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

@MainActor
final class ShaarDevToolsFloatingWindow: NSObject, NSWindowDelegate {
  private let model: ShaarDevToolsModel
  private let window: NSWindow
  private var dismissing = false

  init(model: ShaarDevToolsModel, inspector: InspectorModel?, openChromium: @escaping () -> Void) {
    self.model = model
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 850, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    super.init()
    window.title = ShellL10n.string("Shaar DevTools")
    window.minSize = NSSize(width: 360, height: 280)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(
      rootView: ShaarDevToolsPanel(
        model: model, inspector: inspector, openChromium: openChromium
      ).shellLocalization())
    window.center()
  }

  func present() {
    window.orderFront(nil)
  }

  func isWindow(_ candidate: NSWindow) -> Bool {
    window === candidate
  }

  func dismiss() {
    dismissing = true
    window.close()
  }

  func windowWillClose(_ notification: Notification) {
    guard !dismissing else { return }
    model.floatingWindow = nil
    model.close()
  }
}
