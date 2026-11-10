// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Which developer tools F12 and Option-Command-I open.
enum ShaarDevToolsRoute {
  /// Hidden debug default. Absent or false: those shortcuts open the Chromium
  /// dock. True: they open the SwiftUI shell until that shell is retired.
  static let legacyShellDefaultsKey = "shaar.devtools.legacyShell"

  static func opensLegacyShell(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: legacyShellDefaultsKey)
  }

  /// The menu command F12 performs.
  static func f12Command(_ defaults: UserDefaults = .standard) -> BrowserMenuCommand {
    opensLegacyShell(defaults) ? .developerTools : .chromiumDeveloperTools
  }
}
