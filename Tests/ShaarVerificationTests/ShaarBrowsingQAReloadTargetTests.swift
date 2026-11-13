// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
import Foundation

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAReloadTargetTests {
  @Test func reloadTargetEvidenceRequiresTheExactRequestedURL() {
    let target = URL(string: "http://127.0.0.1:8123/slow?reloadTarget=1")!
    #expect(ShaarBrowsingQA.matchesReloadTarget(target.absoluteString, expected: target))
    #expect(
      !ShaarBrowsingQA.matchesReloadTarget(
        "http://127.0.0.1:8123/slow", expected: target))
    #expect(
      !ShaarBrowsingQA.matchesReloadTarget(
        "http://localhost:8123/slow?reloadTarget=1", expected: target))
    #expect(!ShaarBrowsingQA.matchesReloadTarget(nil, expected: target))
  }
}
