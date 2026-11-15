// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQARunLoopTests {
  @Test func runLoopWatchdogRequiresEnoughSamples() {
    #expect(!ShaarBrowsingQA.heavyPageRunLoopPassed(samples: 0, maximumDelayMs: 0))
    #expect(!ShaarBrowsingQA.heavyPageRunLoopPassed(samples: 1, maximumDelayMs: 0))
  }

  @Test func runLoopWatchdogAllowsTheConfiguredDelayBoundary() {
    #expect(ShaarBrowsingQA.heavyPageRunLoopPassed(samples: 2, maximumDelayMs: 1000))
    #expect(!ShaarBrowsingQA.heavyPageRunLoopPassed(samples: 2, maximumDelayMs: 1001))
  }
}
