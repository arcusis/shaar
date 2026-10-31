// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Sparkle

/// Wraps Sparkle so only bundles built with an update feed check for updates.
@MainActor
final class AppUpdater {
  private let controller: SPUStandardUpdaterController?

  init(enabled: Bool) {
    controller =
      enabled
      ? SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
      : nil
  }

  /// Create after the engine's application object exists; Sparkle touches `NSApp`.
  static func forMainBundle() -> AppUpdater {
    AppUpdater(enabled: UpdateFeed.isConfigured(in: Bundle.main.infoDictionary ?? [:]))
  }

  var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}
