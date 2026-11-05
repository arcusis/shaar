// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

@Test func macPermissionsGuidanceUsesTheSelectedLanguage() {
  #expect(
    BrowserSettingsCopy.macPermissionsFooter(language: .english)
      == "Websites can only use what macOS allows. If a site's request is blocked here, change it in System Settings."
  )
  #expect(
    BrowserSettingsCopy.macPermissionsFooter(language: .hebrew)
      == "אתרים יכולים להשתמש רק בהרשאות ש‑macOS מאפשרת. אם בקשת אתר חסומה כאן, יש לשנות זאת בהגדרות המערכת."
  )
}
