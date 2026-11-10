// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func f12OpensChromiumDevToolsUnlessTheLegacyShellDefaultIsSet() {
  let off = UserDefaults(suiteName: "shaar-devtools-route-off.\(UUID().uuidString)")!
  let on = UserDefaults(suiteName: "shaar-devtools-route-on.\(UUID().uuidString)")!
  on.set(true, forKey: ShaarDevToolsRoute.legacyShellDefaultsKey)

  #expect(!ShaarDevToolsRoute.opensLegacyShell(off))
  #expect(ShaarDevToolsRoute.f12Command(off) == .chromiumDeveloperTools)
  #expect(ShaarDevToolsRoute.opensLegacyShell(on))
  #expect(ShaarDevToolsRoute.f12Command(on) == .developerTools)
  #expect(ShortcutCatalog.displayKeys(for: .developerTools) == "⌥⌘I")
  #expect(ShortcutCatalog.displayKeys(for: .chromiumDeveloperTools) == "⌥⇧⌘I")
}

@Test func smokeSuiteKeepsTheLegacyShellOffTheUserDefaults() throws {
  let key = ShaarDevToolsRoute.legacyShellDefaultsKey
  let previous = ShaarDevToolsRoute.defaults
  let standardHadKey = UserDefaults.standard.object(forKey: key) != nil
  let standardValue = UserDefaults.standard.bool(forKey: key)
  let name = "shaar.devtools.route-smoke.\(UUID().uuidString)"
  defer {
    ShaarDevToolsRoute.restoreLegacyShellDefaults(suite: name)
    ShaarDevToolsRoute.defaults = previous
  }
  let suite = try #require(ShaarDevToolsRoute.isolateLegacyShell(suite: name))

  #expect(!ShaarDevToolsRoute.opensLegacyShell())
  #expect(ShaarDevToolsRoute.f12Command() == .chromiumDeveloperTools)
  suite.set(true, forKey: key)
  #expect(ShaarDevToolsRoute.opensLegacyShell())
  #expect(ShaarDevToolsRoute.opensLegacyShell(suite))
  #expect(ShaarDevToolsRoute.f12Command() == .developerTools)
  #expect(UserDefaults.standard.bool(forKey: key) == standardValue)
  #expect((UserDefaults.standard.object(forKey: key) != nil) == standardHadKey)
}
