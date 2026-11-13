// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingEdgeProbePageScaleTests {
  @Test func pageScaleAcceptsOnlyPositiveFiniteJSONNumbers() {
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"scale":1}"#) == 1)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"scale":1.25}"#) == 1.25)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"scale":true}"#) == nil)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"scale":0}"#) == nil)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"scale":-1}"#) == nil)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"scale":"1.25"}"#) == nil)
  }

  @Test func pageScaleRejectsMissingAndMalformedEvidence() {
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: nil) == nil)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: "not JSON") == nil)
    #expect(ShaarBrowsingEdgeProbe.pageScale(from: #"{"other":1}"#) == nil)
  }
}
