// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct PrivateNavigationReadinessTests {
  private let firstVisit = "private-product-edbe3384-923c-4013-bc6c-8808dd3d1d69-a"
  private let nextVisit = "private-product-edbe3384-923c-4013-bc6c-8808dd3d1d69-next"
  private let nextURL =
    "http://127.0.0.1:49195/account/private-product-edbe3384-923c-4013-bc6c-8808dd3d1d69-next"
  private let firstURL =
    "http://127.0.0.1:49195/account/private-product-edbe3384-923c-4013-bc6c-8808dd3d1d69-a"

  @Test func settledDocumentMatchesOnlyACommittedPhase() {
    for phase in PrivateNavigationReadiness.settledPhases {
      #expect(
        PrivateNavigationReadiness.hasSettled(
          url: firstURL, loading: false, phase: phase, contains: firstVisit))
    }
    for phase in ["started", "stopped", "failed", "none", "unknown"] {
      #expect(
        !PrivateNavigationReadiness.hasSettled(
          url: firstURL, loading: false, phase: phase, contains: firstVisit))
    }
  }

  @Test func provisionalOrLoadingNavigationDoesNotSettle() {
    #expect(
      !PrivateNavigationReadiness.hasSettled(
        url: firstURL, loading: true, phase: "started", contains: firstVisit))
    #expect(
      !PrivateNavigationReadiness.hasSettled(
        url: firstURL, loading: true, phase: "committed", contains: firstVisit))
    #expect(
      !PrivateNavigationReadiness.hasSettled(
        url: firstURL, loading: false, phase: nil, contains: firstVisit))
    #expect(
      !PrivateNavigationReadiness.hasSettled(
        url: nil, loading: false, phase: "finished", contains: firstVisit))
  }

  @Test func backTargetDoesNotMatchThePageThatWasJustLoaded() {
    #expect(
      PrivateNavigationReadiness.hasSettled(
        url: nextURL, loading: false, phase: "finished", contains: nextVisit))
    #expect(
      !PrivateNavigationReadiness.hasSettled(
        url: nextURL, loading: false, phase: "finished", contains: firstVisit))
    #expect(
      !PrivateNavigationReadiness.hasSettled(
        url: "about:blank", loading: false, phase: "finished", contains: firstVisit))
    #expect(
      PrivateNavigationReadiness.hasSettled(
        url: firstURL, loading: false, phase: "finished", contains: firstVisit))
  }
}
