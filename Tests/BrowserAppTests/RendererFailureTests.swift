// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct RendererFailureTests {
  @Test @MainActor func recoveryTitleIsVoiceOverHeading() {
    #expect(FailedPageView.headingTraits.contains(.isHeader))
  }

  @Test(arguments: ["oom", "evicted"])
  func memoryFailuresExplainTheRecoveryChoice(status: String) {
    let failure = RendererFailure(
      profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://example.test")!,
      status: status, exitCode: 1)

    #expect(
      failure.message
        == "This page ran out of memory. Reload it, or switch to another tab.")
  }

  @Test func otherRendererFailuresUseTheGeneralRecoveryMessage() {
    let failure = RendererFailure(
      profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://example.test")!,
      status: "crashed", exitCode: 1)

    #expect(failure.message == "Reload this page, or switch to another tab to continue.")
  }
}
