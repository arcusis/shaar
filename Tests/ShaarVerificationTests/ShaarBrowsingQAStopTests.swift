// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAStopTests {
  @Test func stopLoadingProbeRequiresAnInFlightNavigationAndPreservedCommittedPage() {
    #expect(
      ShaarBrowsingQA.stopLoadingPassed(
        started: true, accepted: true, loadingEnded: true, committedPagePreserved: true))
    #expect(
      !ShaarBrowsingQA.stopLoadingPassed(
        started: false, accepted: true, loadingEnded: true, committedPagePreserved: true))
    #expect(
      !ShaarBrowsingQA.stopLoadingPassed(
        started: true, accepted: false, loadingEnded: true, committedPagePreserved: true))
    #expect(
      !ShaarBrowsingQA.stopLoadingPassed(
        started: true, accepted: true, loadingEnded: false, committedPagePreserved: true))
    #expect(
      !ShaarBrowsingQA.stopLoadingPassed(
        started: true, accepted: true, loadingEnded: true, committedPagePreserved: false))
  }
}
