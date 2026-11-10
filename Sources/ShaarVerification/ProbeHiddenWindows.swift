// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

/// Hidden engine probes keep every AppKit window ordered out. Closing a key
/// private window can leave a Chromium browser widget visible, and popup
/// evaluation stops while any window is on screen.
@MainActor
enum ProbeHiddenWindows {
  static func orderOutVisibleWindows() {
    NSApp.modalWindow?.orderOut(nil)
    for window in NSApp.windows where window.isVisible {
      window.orderOut(nil)
    }
  }
}
