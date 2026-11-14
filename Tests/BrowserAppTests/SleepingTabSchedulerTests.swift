// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SleepingTabSchedulerTests {
  @Test func activeLifecycleTransitionRestartsBackgroundIdleTimeout() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://background.example/page")!))
    let tabID = try #require(store.session.selectedSpace.selectedTabID)
    store.perform(.open(URL(string: "https://selected.example/page")!))
    let candidate = SleepingTabScheduler.Candidate(
      id: tabID, host: "background.example", isPinned: false, keepAlive: false,
      isVisible: false, isPrivateActive: false, isPlaying: false, isCapturing: false,
      hasInspector: false, hasDeveloperTools: false, hasAgentConnection: false,
      profileIsDownloading: false, isLive: true)
    let scheduler = SleepingTabScheduler()
    scheduler.capability = .capable
    scheduler.policy = { SleepingTabsPolicy(timeout: 10) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var slept: [UUID] = []
    let probe: @MainActor (UUID, @MainActor (Bool) -> Void) -> Void = { _, done in done(true) }
    let evaluate: @MainActor (UUID, @MainActor (String?) -> Void) -> Void = {
      _, done in done("{\"edited\":false}")
    }
    let sleep: @MainActor (UUID, String, @MainActor (Bool) -> Void) -> Void = { id, _, done in
      slept.append(id)
      done(true)
    }
    let fresh: @MainActor () -> [SleepingTabScheduler.Candidate] = { [candidate] }
    let onSlept: @MainActor (UUID) -> Void = { _ in }

    scheduler.consider(
      [candidate], now: now, sleeping: [], urgent: false, probe: probe, evaluate: evaluate,
      sleep: sleep, fresh: fresh, onSlept: onSlept)
    scheduler.apply(state: "frozen", audible: false, capturing: false, id: tabID, store: store)
    scheduler.apply(state: "active", audible: false, capturing: false, id: tabID, store: store)
    scheduler.consider(
      [candidate], now: now.addingTimeInterval(11), sleeping: store.sleepingTabIDs, urgent: false,
      probe: probe, evaluate: evaluate, sleep: sleep, fresh: fresh, onSlept: onSlept)

    #expect(slept.isEmpty)
    #expect(!store.sleepingTabIDs.contains(tabID))
  }

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
