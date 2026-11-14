// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge

@testable import ArcusisBrowser

/// The account-isolation fixture is a component extension, so the product
/// extension list omits it. Later probes open its popup with the id from the
/// load that installed it. The action reply arrives after execute returns.
@MainActor
enum ProbeExtensionFixture {
  enum PopupOpen {
    case unavailable
    case didNotOpen
    case opened(ExtensionPopupContext)
  }

  private(set) static var accountIsolationID: String?

  static func hasNewNotice(since priorNotice: String?, currentNotice: String?) -> Bool {
    guard let currentNotice else { return false }
    return currentNotice != priorNotice
  }

  static func rememberAccountIsolation(_ id: String) {
    accountIsolationID = id
  }

  static func openPopup(on engine: BrowserEngine) async -> PopupOpen {
    guard let id = accountIsolationID else { return .unavailable }
    let priorNotice = engine.notice
    engine.executeExtension(id)
    for _ in 0..<50 {
      if case .popup(let popup) = engine.extensionPanel,
        engine.runtime.view(forExtensionPopupID: popup.id) != nil
      {
        return .opened(popup)
      }
      if hasNewNotice(since: priorNotice, currentNotice: engine.notice) {
        return .didNotOpen
      }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return .didNotOpen
      }
    }
    return .didNotOpen
  }
}
