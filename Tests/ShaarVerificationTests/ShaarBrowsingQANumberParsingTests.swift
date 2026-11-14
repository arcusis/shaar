// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQANumberParsingTests {
  @Test func wholeNumberTrimsAndParsesIntegerResponseValues() {
    #expect(ShaarBrowsingQA.wholeNumber(" 200\n") == 200)
    #expect(ShaarBrowsingQA.wholeNumber("0") == 0)
    #expect(ShaarBrowsingQA.wholeNumber("-1") == -1)
  }

  @Test func wholeNumberRejectsMissingEmptyNonIntegerAndOverflowValues() {
    #expect(ShaarBrowsingQA.wholeNumber(nil) == nil)
    #expect(ShaarBrowsingQA.wholeNumber(" \n\t") == nil)
    #expect(ShaarBrowsingQA.wholeNumber("200.5") == nil)
    #expect(ShaarBrowsingQA.wholeNumber("999999999999999999999999999999") == nil)
  }

  @Test func reloadDuringNavigationRequiresASecondFixtureRequest() {
    #expect(!ShaarBrowsingQA.reloadDuringNavigationWasFetched(nil))
    #expect(!ShaarBrowsingQA.reloadDuringNavigationWasFetched("1"))
    #expect(ShaarBrowsingQA.reloadDuringNavigationWasFetched("2"))
    #expect(ShaarBrowsingQA.reloadDuringNavigationWasFetched("3"))
    #expect(!ShaarBrowsingQA.reloadDuringNavigationWasFetched("loading"))
  }
}
