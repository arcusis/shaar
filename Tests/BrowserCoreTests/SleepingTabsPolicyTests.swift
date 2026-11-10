// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Suite struct SleepingTabsPolicyTests {
  @Test func hostKeyTrimsCaseAndLeadingWWW() {
    #expect(SleepingTabsPolicy.hostKey(" WWW.Example.COM ") == "example.com")
    #expect(SleepingTabsPolicy.hostKey("example.com") == "example.com")
    #expect(SleepingTabsPolicy.hostKey("notwww.example.com") == "notwww.example.com")
  }

  @Test func exemptionsCoverVisibleSoundCaptureFormsPinsAndThePrivateSelection() {
    let policy = SleepingTabsPolicy(neverSleepHosts: ["bank.test"])
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let idle = facts(lastActive: now.addingTimeInterval(-policy.timeout - 1))
    #expect(policy.isIdle(idle, now: now))
    #expect(!policy.isIdle(facts(isPinned: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(keepAlive: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(isVisible: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(isPrivateActive: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(isPlaying: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(isCapturing: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(formEdited: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(hasInspector: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(hasDeveloperTools: true, lastActive: idle.lastActive), now: now))
    #expect(
      !policy.isIdle(facts(profileIsDownloading: true, lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(host: "www.bank.test", lastActive: idle.lastActive), now: now))
    #expect(!policy.isIdle(facts(lastActive: now.addingTimeInterval(-60)), now: now))
  }

  @Test func disabledPolicyDiscardsNothing() {
    let policy = SleepingTabsPolicy(enabled: false, timeout: 1)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let tabs = [facts(lastActive: now.addingTimeInterval(-100))]
    #expect(policy.idleTabs(tabs, now: now).isEmpty)
    #expect(policy.memoryPressureTabs(tabs).isEmpty)
  }

  @Test func memoryPressureKeepsTheFourOldestEligibleTabs() {
    let policy = SleepingTabsPolicy()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var tabs: [SleepingTabFacts] = []
    for offset in 0..<6 {
      tabs.append(facts(lastActive: start.addingTimeInterval(TimeInterval(offset))))
    }
    tabs.append(facts(isPinned: true, lastActive: start.addingTimeInterval(-100)))
    let chosen = policy.memoryPressureTabs(tabs)
    #expect(chosen == Array(tabs.prefix(4).map(\.id)))
    let tied = (0..<6).map { _ in facts(lastActive: start) }
    #expect(policy.memoryPressureTabs(tied) == Array(tied.prefix(4).map(\.id)))
  }

  @Test func preferencesDefaultToTwoHoursAndParseNeverSleepHosts() {
    let name = "sleeping-tabs-policy-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let fresh = SleepingTabPreferences.policy(defaults: defaults)
    #expect(fresh.enabled)
    #expect(fresh.timeout == SleepingTabsPolicy.defaultTimeout)
    defaults.set(false, forKey: SleepingTabPreferences.enabledKey)
    defaults.set(7, forKey: SleepingTabPreferences.timeoutMinutesKey)
    defaults.set(
      "Mail.Example.com, www.bank.test\nnews.example.com",
      forKey: SleepingTabPreferences.neverSleepHostsKey)
    let stored = SleepingTabPreferences.policy(defaults: defaults)
    #expect(!stored.enabled)
    #expect(stored.timeout == TimeInterval(SleepingTabPreferences.defaultTimeoutMinutes * 60))
    #expect(stored.neverSleepHosts == ["mail.example.com", "bank.test", "news.example.com"])
    defaults.set(15, forKey: SleepingTabPreferences.timeoutMinutesKey)
    #expect(SleepingTabPreferences.policy(defaults: defaults).timeout == 15 * 60)
  }

  @Test func formSignalReadsEditedAndFailsClosed() {
    #expect(SleepingFormSignal.edited("{\"edited\":false}") == false)
    #expect(SleepingFormSignal.edited("{\"edited\":true}") == true)
    #expect(SleepingFormSignal.edited("{\"x\":1}") == nil)
    #expect(SleepingFormSignal.edited(nil) == nil)
    #expect(!SleepingFormSignal.script.contains("scrollX"))
    #expect(!SleepingFormSignal.script.contains("scrollTo"))
  }

  private func facts(
    host: String = "example.test", isPinned: Bool = false, keepAlive: Bool = false,
    isVisible: Bool = false, isPrivateActive: Bool = false, isPlaying: Bool = false,
    isCapturing: Bool = false, formEdited: Bool = false, hasInspector: Bool = false,
    hasDeveloperTools: Bool = false, profileIsDownloading: Bool = false, lastActive: Date
  ) -> SleepingTabFacts {
    SleepingTabFacts(
      id: UUID(), host: host, isPinned: isPinned, keepAlive: keepAlive, isVisible: isVisible,
      isPrivateActive: isPrivateActive, isPlaying: isPlaying, isCapturing: isCapturing,
      formEdited: formEdited, hasInspector: hasInspector, hasDeveloperTools: hasDeveloperTools,
      profileIsDownloading: profileIsDownloading, lastActive: lastActive)
  }
}
