// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit

@testable import ArcusisBrowser

extension NativeBrowserHost {
  /// The installed menu item for a command, as a person would choose it.
  func menuItem(for command: BrowserMenuCommand) -> NSMenuItem? {
    menu?.items.flatMap { $0.submenu?.items ?? [] }.first {
      $0.representedObject as? String == command.rawValue
    }
  }

  /// Sends a command through its menu item's own action; false when it is missing or disabled.
  func sendMenuCommand(_ command: BrowserMenuCommand) -> Bool {
    guard canPerform(command), let item = menuItem(for: command), let action = item.action else {
      return false
    }
    return NSApp.sendAction(action, to: item.target, from: item)
  }
}
