// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore

enum PasteAndGoCommand {
  static func destination(
    in pasteboard: NSPasteboard, searchEngine: BrowserSearchEngine
  ) -> URL? {
    guard let text = pasteboard.string(forType: .string) else { return nil }
    return NavigationInput.destination(for: text, searchEngine: searchEngine)
  }

  @discardableResult
  static func route(
    in pasteboard: NSPasteboard, searchEngine: BrowserSearchEngine,
    navigate: (URL) -> Bool
  ) -> Bool {
    guard let url = destination(in: pasteboard, searchEngine: searchEngine) else { return false }
    return navigate(url)
  }

  @MainActor @discardableResult
  static func route(
    in pasteboard: NSPasteboard, store: BrowserStore, searchEngine: BrowserSearchEngine,
    navigate: (URL) -> Bool
  ) -> Bool {
    guard let url = destination(in: pasteboard, searchEngine: searchEngine) else { return false }
    guard store.session.selectedPage != nil else {
      store.perform(.open(url))
      return true
    }
    return navigate(url)
  }
}
