// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarFolderHoverDelayTests {
  @Test func staleHoverDelayReleasesSlotForTheNextDrag() async {
    let delay = SidebarFolderHoverDelay()
    let clock = ContinuousClock()
    var activated = false

    delay.schedule(until: clock.now + .milliseconds(1)) { false } activate: {
      activated = true
    }
    await delay.waitForCurrentTask()

    #expect(!delay.isScheduled)
    #expect(!activated)

    delay.schedule(until: clock.now + .milliseconds(1)) { true } activate: {
      activated = true
    }
    await delay.waitForCurrentTask()

    #expect(!delay.isScheduled)
    #expect(activated)
  }
}
