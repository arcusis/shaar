// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite("Browsing edge report scalar parsing")
struct ShaarBrowsingEdgeProbeScalarTests {
  @Test @MainActor func jsonObjectParserRejectsScalarsAndMalformedInput() {
    #expect(
      ShaarBrowsingEdgeProbe.object(from: "{\"marker\":\"ready\"}")?["marker"] as? String
        == "ready")
    #expect(ShaarBrowsingEdgeProbe.object(from: "false") == nil)
    #expect(ShaarBrowsingEdgeProbe.object(from: "[]") == nil)
    #expect(ShaarBrowsingEdgeProbe.object(from: "not JSON") == nil)
    #expect(ShaarBrowsingEdgeProbe.object(from: nil) == nil)
  }

  @Test func integerParserRejectsBooleansFractionsAndOverflow() {
    #expect(ShaarBrowsingEdgeProbe.number(7) == 7)
    #expect(ShaarBrowsingEdgeProbe.number(-2) == -2)
    #expect(ShaarBrowsingEdgeProbe.number(Int64.max) == Int(Int64.max))
    #expect(ShaarBrowsingEdgeProbe.number(2.5) == nil)
    #expect(ShaarBrowsingEdgeProbe.number(true) == nil)
    #expect(ShaarBrowsingEdgeProbe.number(UInt64.max) == nil)
  }

  @Test func integerParserAcceptsExactlyRepresentableFloatingPointValues() {
    #expect(ShaarBrowsingEdgeProbe.number(7.0) == 7)
    #expect(ShaarBrowsingEdgeProbe.number(-2.0) == -2)
    #expect(ShaarBrowsingEdgeProbe.number(2.000_000_000_000_000_4) == nil)
  }

  @Test func booleanParserAcceptsOnlyBooleanValues() {
    #expect(ShaarBrowsingEdgeProbe.flag(true) == true)
    #expect(ShaarBrowsingEdgeProbe.flag(false) == false)
    #expect(ShaarBrowsingEdgeProbe.flag(1) == nil)
    #expect(ShaarBrowsingEdgeProbe.flag("true") == nil)
  }

  @Test func integerArraysDiscardNonIntegerScalars() {
    #expect(ShaarBrowsingEdgeProbe.numbers([1, 2.5, true, "4", 5]) == [1, 5])
    #expect(ShaarBrowsingEdgeProbe.numbers("not an array").isEmpty)
  }

  @Test func videoVerdictRejectsPausedFramesEvenWhenTheyHaveDimensions() {
    #expect(!ShaarBrowsingEdgeProbe.videoIsPlaying([
      "video": true, "paused": true, "videoWidth": 320,
    ]))
    #expect(!ShaarBrowsingEdgeProbe.videoIsPlaying([
      "video": true, "paused": false, "videoWidth": 0,
    ]))
    #expect(!ShaarBrowsingEdgeProbe.videoIsPlaying([
      "video": true, "videoWidth": 320,
    ]))
    #expect(ShaarBrowsingEdgeProbe.videoIsPlaying([
      "video": true, "paused": false, "videoWidth": 320,
    ]))
  }

  @Test func scrollFailureNeedsAnObservedScrollEventToBeAttributable() {
    #expect(!ShaarBrowsingEdgeProbe.scrollFailureIsAttributable(scrollEvents: 0))
    #expect(ShaarBrowsingEdgeProbe.scrollFailureIsAttributable(scrollEvents: 1))
  }

  @Test func infiniteScrollCapturesItsBaselineBeforeTriggeringTheScroll() {
    let baseline = ShaarBrowsingEdgeProbe.scrollStateScript(triggerScroll: false)
    let trigger = ShaarBrowsingEdgeProbe.scrollStateScript(triggerScroll: true)
    #expect(!baseline.contains("scrollIntoView"))
    #expect(!baseline.contains("root.scrollTop="))
    #expect(trigger.contains("scrollIntoView"))
    #expect(trigger.contains("root.scrollTop=root.scrollHeight"))
  }
}
