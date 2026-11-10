// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Which developer tools F12 and Option-Command-I open.
enum ShaarDevToolsRoute {
  /// Hidden debug default. Absent or false: those shortcuts open the Chromium
  /// dock. True: they open the SwiftUI shell until that shell is retired.
  static let legacyShellDefaultsKey = "shaar.devtools.legacyShell"

  /// No-argument reads use this object. Production leaves it at `.standard`.
  /// A smoke points it at a private suite so a crash cannot stick the user's default.
  static var defaults: UserDefaults {
    get { legacyShellDefaults.value }
    set { legacyShellDefaults.value = newValue }
  }

  private static let legacyShellDefaults = LegacyShellDefaultsBox(.standard)

  static func opensLegacyShell(_ defaults: UserDefaults = ShaarDevToolsRoute.defaults) -> Bool {
    defaults.bool(forKey: legacyShellDefaultsKey)
  }

  /// The menu command F12 performs.
  static func f12Command(_ defaults: UserDefaults = ShaarDevToolsRoute.defaults)
    -> BrowserMenuCommand
  {
    opensLegacyShell(defaults) ? .developerTools : .chromiumDeveloperTools
  }

  /// Clears `name` and points no-argument reads at that suite. The suite starts
  /// with the legacy shell off.
  @discardableResult
  static func isolateLegacyShell(suite name: String) -> UserDefaults? {
    guard let suite = UserDefaults(suiteName: name) else { return nil }
    suite.removePersistentDomain(forName: name)
    suite.removeObject(forKey: legacyShellDefaultsKey)
    defaults = suite
    return suite
  }

  /// Drops the suite and points no-argument reads back at `.standard`.
  static func restoreLegacyShellDefaults(suite name: String) {
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    defaults = .standard
  }

  /// F12 and Option-Command-I. The Chromium dock is the public path, and an
  /// open SwiftUI shell closes before that dock toggles.
  @MainActor static func performPublicToggle(
    shell: ShaarDevToolsModel?,
    toggleShell: @MainActor () -> Void,
    toggleChromium: @MainActor () -> Void
  ) {
    if opensLegacyShell() {
      toggleShell()
    } else {
      closeOpenShell(shell)
      toggleChromium()
    }
  }

  /// Closes an open SwiftUI shell only while the public route is the Chromium dock.
  /// A second call does nothing once `isOpen` is false.
  @MainActor static func closeOpenShell(_ shell: ShaarDevToolsModel?) {
    guard !opensLegacyShell(), let shell, shell.isOpen else { return }
    shell.close()
  }
}

/// The smokes replace this pointer for one process. The lock keeps that swap
/// concurrency-safe; `UserDefaults` itself is safe to read from either side.
private final class LegacyShellDefaultsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: UserDefaults

  init(_ storage: UserDefaults) {
    self.storage = storage
  }

  var value: UserDefaults {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storage = newValue
    }
  }
}
