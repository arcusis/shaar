// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Testing
@testable import ArcusisBrowser

struct BrowserEngineSiteControlsTests {
  @Test func developerPageActionFailuresUseHebrewActionAndRecoveryCopy() {
    #expect(
      SiteAction.hardReload.failureNotice(language: .hebrew)
        == "לא ניתן להשלים את הפעולה \u{2068}טעינה מחדש מלאה\u{2069}. כדאי לנסות שוב.")
  }

  @Test func reloadModesMapToTheirChromiumCounterparts() {
    #expect(PageReloadMode.normal.engineMode == .normal)
    #expect(PageReloadMode.bypassingCache.engineMode == .bypassingCache)
    #expect(PageReloadMode.newRenderer.engineMode == .newRenderer)
  }
}
