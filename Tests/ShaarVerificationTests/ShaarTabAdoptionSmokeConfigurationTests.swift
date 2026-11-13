// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarTabAdoptionSmokeConfigurationTests {
  @Test func pageMustUseAuthoredLoopbackHttpBeforeRuntimeCreation() {
    let invalid: [URL?] = [
      nil,
      URL(string: "https://127.0.0.1:8080/"),
      URL(string: "http://localhost:8080/"),
      URL(string: "http://example.invalid:8080/"),
    ]
    for page in invalid {
      #expect(
        ShaarTabAdoptionSmoke.run(
          frameworkURL: URL(filePath: "/missing/Chromium Framework.framework"),
          outputURL: FileManager.default.temporaryDirectory.appending(path: "tab-adoption.json"),
          pageURL: page) == 2)
    }
  }
}
