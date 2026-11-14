// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAProfileSwitchTests {
  @Test func midNavigationSwitchMustLandOnTheRequestedPage() {
    #expect(
      ShaarBrowsingQA.profileSwitchNavigationPassed(
        switched: true, settled: true, profileMatched: true,
        landedPath: "/slow", rendererFailures: 0))
    #expect(
      !ShaarBrowsingQA.profileSwitchNavigationPassed(
        switched: true, settled: true, profileMatched: true,
        landedPath: "/nav/1", rendererFailures: 0))
  }

  @Test func profileSwitchFailureConditionsStillFail() {
    #expect(
      !ShaarBrowsingQA.profileSwitchNavigationPassed(
        switched: false, settled: true, profileMatched: true,
        landedPath: "/slow", rendererFailures: 0))
    #expect(
      !ShaarBrowsingQA.profileSwitchNavigationPassed(
        switched: true, settled: false, profileMatched: true,
        landedPath: "/slow", rendererFailures: 0))
    #expect(
      !ShaarBrowsingQA.profileSwitchNavigationPassed(
        switched: true, settled: true, profileMatched: false,
        landedPath: "/slow", rendererFailures: 0))
    #expect(
      !ShaarBrowsingQA.profileSwitchNavigationPassed(
        switched: true, settled: true, profileMatched: true,
        landedPath: "/slow", rendererFailures: 1))
  }
}
