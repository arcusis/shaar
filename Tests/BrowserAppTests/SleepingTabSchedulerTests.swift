// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SleepingTabSchedulerTests {
  @Test(arguments: [(true, false), (false, true)])
  func forgettingAnUnknownTabClearsCachedActivitySignals(audible: Bool, capturing: Bool) {
    let id = UUID()
    let candidate = SleepingTabScheduler.Candidate(
      id: id, host: "media.example", isPinned: false, keepAlive: false,
      isVisible: false, isPrivateActive: false, isPlaying: false, isCapturing: false,
      hasInspector: false, hasDeveloperTools: false, hasAgentConnection: false,
      profileIsDownloading: false, isLive: true)
    let scheduler = SleepingTabScheduler()
    scheduler.capability = .capable
    scheduler.policy = { SleepingTabsPolicy() }
    scheduler.noteSignal(id, audible: audible, capturing: capturing)
    var slept: [UUID] = []
    let probe: @MainActor (UUID, @MainActor (Bool) -> Void) -> Void = { _, done in done(true) }
    let evaluate: @MainActor (UUID, @MainActor (String?) -> Void) -> Void = {
      _, done in done("{\"edited\":false}")
    }
    let sleep: @MainActor (UUID, String, @MainActor (Bool) -> Void) -> Void = { tabID, _, done in
      done(true)
      slept.append(tabID)
    }
    let fresh: @MainActor () -> [SleepingTabScheduler.Candidate] = { [candidate] }
    let onSlept: @MainActor (UUID) -> Void = { _ in }

    scheduler.consider(
      [candidate], now: Date(timeIntervalSince1970: 1_800_000_000), sleeping: [], urgent: true,
      probe: probe, evaluate: evaluate, sleep: sleep, fresh: fresh, onSlept: onSlept)
    #expect(slept.isEmpty)

    scheduler.apply(
      state: "active", audible: false, capturing: false, id: id, store: BrowserStore())
    scheduler.consider(
      [candidate], now: Date(timeIntervalSince1970: 1_800_000_001), sleeping: [], urgent: true,
      probe: probe, evaluate: evaluate, sleep: sleep, fresh: fresh, onSlept: onSlept)

    #expect(slept == [id])
  }
}
