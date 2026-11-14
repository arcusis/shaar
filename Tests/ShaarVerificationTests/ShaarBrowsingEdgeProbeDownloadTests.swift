// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbeDownloadTests {
  @Test func downloadRowRequiresPauseToBeAcceptedAndObserved() {
    #expect(ShaarBrowsingEdgeProbe.downloadPauseWasVerified(asked: true, held: true))
    #expect(!ShaarBrowsingEdgeProbe.downloadPauseWasVerified(asked: false, held: true))
    #expect(!ShaarBrowsingEdgeProbe.downloadPauseWasVerified(asked: true, held: false))
    #expect(!ShaarBrowsingEdgeProbe.downloadPauseWasVerified(asked: false, held: false))
  }
}
