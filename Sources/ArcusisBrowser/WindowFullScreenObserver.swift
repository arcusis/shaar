// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

private struct BrowserWindowIsFullScreenKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Full screen hides the traffic lights, so titlebar-row controls move into the sidebar.
  var browserWindowIsFullScreen: Bool {
    get { self[BrowserWindowIsFullScreenKey.self] }
    set { self[BrowserWindowIsFullScreenKey.self] = newValue }
  }
}

/// Reports whether the hosting window is in full screen.
struct WindowFullScreenObserver: NSViewRepresentable {
  @Binding var isFullScreen: Bool

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.onChange = { value in
      if isFullScreen != value { isFullScreen = value }
    }
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {}

  final class ObserverView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      let center = NotificationCenter.default
      for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
      {
        observers.append(
          center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            self?.report()
          })
      }
      report()
    }

    private func report() {
      onChange?(window?.styleMask.contains(.fullScreen) == true)
    }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
  }
}
