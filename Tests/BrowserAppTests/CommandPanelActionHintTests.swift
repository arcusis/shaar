// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test @MainActor func configuredSearchEnginesUseSearchActionHint() {
  let panel = CommandPanel(store: BrowserStore(), resultsHeight: 120)
  for engine in BrowserSearchEngine.allCases {
    let destination = NavigationInput.destination(for: "test query", searchEngine: engine)!
    #expect(panel.isWebSearch(destination), "\(engine.displayName) search was labeled Open")
  }
  #expect(!panel.isWebSearch(URL(string: "https://www.google.com/mail?q=test")!))
}
