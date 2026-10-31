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
    let configuration = UpdateFeedConfiguration(
      infoDictionary: Bundle.main.infoDictionary ?? [:])
    return AppUpdater(enabled: configuration != nil)
  }

  var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}
