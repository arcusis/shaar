// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

@Suite struct SleepingTabsSettingsTests {
  @Test func exemptionHelpNamesTheRulesInEnglishAndHebrew() {
    let key =
      "One site per line. Pinned and visible tabs, tabs playing sound or using camera, microphone, or screen capture, and tabs with unsaved form input stay awake."
    let english = BrowserLocalization.string(key, table: "Settings", language: .english)
    let hebrew = BrowserLocalization.string(key, table: "Settings", language: .hebrew)

    #expect(english == key)
    #expect(english.contains("camera, microphone, or screen capture"))
    #expect(english.contains("unsaved form input"))
    #expect(hebrew != key)
    #expect(hebrew.contains("במצלמה"))
    #expect(hebrew.contains("קלט טופס שלא נשמר"))
  }
}
