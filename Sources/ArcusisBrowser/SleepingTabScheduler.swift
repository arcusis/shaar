// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// Decides which live tabs to discard. One scheduler per window, including a private window.
@MainActor
final class SleepingTabScheduler {
  enum Capability {
    case unknown
    case probing
    case capable
    case incapable
  }

  struct Candidate: Equatable, Sendable {
    var id: UUID
    var host: String
    var isPinned: Bool
    var keepAlive: Bool
    var isVisible: Bool
    var isPrivateActive: Bool
    var isPlaying: Bool
    var isCapturing: Bool
    var hasInspector: Bool
    var hasDeveloperTools: Bool
    var profileIsDownloading: Bool
    var isLive: Bool
  }

  var capability: Capability = .unknown
  var policy: @MainActor () -> SleepingTabsPolicy = { SleepingTabPreferences.policy() }

  private var inactiveSince: [UUID: Date] = [:]
  private var pending: Set<UUID> = []
  private var audible: [UUID: Bool] = [:]
  private var capturing: [UUID: Bool] = [:]
  private var urgentPending = false

  func forget(_ id: UUID) {
    inactiveSince[id] = nil
    pending.remove(id)
    audible[id] = nil
    capturing[id] = nil
  }

  func noteSignal(_ id: UUID, audible isAudible: Bool, capturing isCapturing: Bool) {
    audible[id] = isAudible
    capturing[id] = isCapturing
  }

  func apply(
    state: String, audible isAudible: Bool, capturing isCapturing: Bool, id: UUID,
    store: BrowserStore
  ) {
    guard store.session.page(forTabID: id) != nil else {
      forget(id)
      store.noteTabAwake(id)
      return
    }
    noteSignal(id, audible: isAudible, capturing: isCapturing)
    if state == "active" || isAudible || isCapturing {
      store.noteTabAwake(id)
      return
    }
    if state == "discarded" || state == "frozen" {
      let onScreen =
        store.session.selectedPage?.tab.id == id || store.visiblePageIDs.contains(id)
      if onScreen {
        store.noteTabAwake(id)
        return
      }
      store.noteTabSleeping(id)
    }
  }

  func consider(
    _ candidates: [Candidate], now: Date, sleeping: Set<UUID>, urgent: Bool,
    probe: @escaping @MainActor (UUID, @escaping @MainActor (Bool) -> Void) -> Void,
    evaluate: @escaping @MainActor (UUID, @escaping @MainActor (String?) -> Void) -> Void,
    sleep: @escaping @MainActor (UUID, String, @escaping @MainActor (Bool) -> Void) -> Void,
    fresh: @escaping @MainActor () -> [Candidate],
    onSlept: @escaping @MainActor (UUID) -> Void
  ) {
    if urgent { urgentPending = true }
    let rules = policy()
    if !rules.enabled {
      inactiveSince.removeAll()
      return
    }
    guard let sample = candidates.first(where: \.isLive)?.id else { return }
    switch capability {
    case .unknown:
      capability = .probing
      probe(sample) { [weak self] capable in
        guard let self else { return }
        self.capability = capable ? .capable : .incapable
        guard capable else { return }
        let runUrgent = self.urgentPending
        self.urgentPending = false
        if runUrgent {
          self.consider(
            candidates, now: now, sleeping: sleeping, urgent: true, probe: probe,
            evaluate: evaluate, sleep: sleep, fresh: fresh, onSlept: onSlept)
        }
        self.consider(
          candidates, now: now, sleeping: sleeping, urgent: false, probe: probe,
          evaluate: evaluate, sleep: sleep, fresh: fresh, onSlept: onSlept)
      }
    case .probing, .incapable:
      return
    case .capable:
      if urgent { urgentPending = false }
      requestSleep(
        candidates, now: now, sleeping: sleeping, urgent: urgent, rules: rules,
        evaluate: evaluate, sleep: sleep, fresh: fresh, onSlept: onSlept)
    }
  }

  private func requestSleep(
    _ candidates: [Candidate], now: Date, sleeping: Set<UUID>, urgent: Bool,
    rules: SleepingTabsPolicy,
    evaluate: @escaping @MainActor (UUID, @escaping @MainActor (String?) -> Void) -> Void,
    sleep: @escaping @MainActor (UUID, String, @escaping @MainActor (Bool) -> Void) -> Void,
    fresh: @escaping @MainActor () -> [Candidate],
    onSlept: @escaping @MainActor (UUID) -> Void
  ) {
    let reason = urgent ? "urgent" : "proactive"
    for id in choices(candidates, now: now, sleeping: sleeping, urgent: urgent, rules: rules) {
      pending.insert(id)
      evaluate(id) { [weak self] result in
        guard let self else { return }
        self.pending.remove(id)
        guard SleepingFormSignal.edited(result) == false else { return }
        guard self.stillWants(id, now: now, urgent: urgent, fresh: fresh) else { return }
        self.pending.insert(id)
        sleep(id, reason) { [weak self] accepted in
          guard let self else { return }
          self.pending.remove(id)
          // The tab can close while the discard is in flight. Marking it then
          // would put a dead id back into the sleeping set.
          guard accepted, fresh().contains(where: { $0.id == id }) else { return }
          self.inactiveSince[id] = nil
          onSlept(id)
        }
      }
    }
  }

  private func stillWants(
    _ id: UUID, now: Date, urgent: Bool, fresh: @MainActor () -> [Candidate]
  ) -> Bool {
    let rules = policy()
    guard rules.enabled, let candidate = fresh().first(where: { $0.id == id && $0.isLive })
    else { return false }
    let facts = makeFacts(candidate, lastActive: inactiveSince[id] ?? now)
    if rules.isExempt(facts) { return false }
    if urgent { return true }
    return rules.isIdle(facts, now: now)
  }

  private func choices(
    _ candidates: [Candidate], now: Date, sleeping: Set<UUID>, urgent: Bool,
    rules: SleepingTabsPolicy
  ) -> [UUID] {
    let facts = stamped(candidates, now: now, rules: rules)
    let pool = urgent ? rules.memoryPressureTabs(facts) : rules.idleTabs(facts, now: now)
    let available = pool.filter { !sleeping.contains($0) && !pending.contains($0) }
    if urgent { return Array(available.prefix(SleepingTabsPolicy.memoryPressureLimit)) }
    return available
  }

  static func candidates(
    tabs: [BrowserTab], liveTabs: Set<UUID>, visible: Set<UUID>,
    isPrivateActive: (UUID) -> Bool, isPlaying: (UUID) -> Bool, isCapturing: (UUID) -> Bool,
    hasInspector: (UUID) -> Bool, hasDeveloperTools: (UUID) -> Bool,
    profileIsDownloading: (UUID) -> Bool
  ) -> [Candidate] {
    var seen: Set<UUID> = []
    var candidates: [Candidate] = []
    for tab in tabs where seen.insert(tab.id).inserted {
      candidates.append(
        Candidate(
          id: tab.id, host: tab.url.host() ?? "", isPinned: tab.isPinned,
          keepAlive: tab.keepAlive, isVisible: visible.contains(tab.id),
          isPrivateActive: isPrivateActive(tab.id), isPlaying: isPlaying(tab.id),
          isCapturing: isCapturing(tab.id), hasInspector: hasInspector(tab.id),
          hasDeveloperTools: hasDeveloperTools(tab.id),
          profileIsDownloading: profileIsDownloading(tab.id),
          isLive: liveTabs.contains(tab.id)))
    }
    return candidates
  }

  private func stamped(
    _ candidates: [Candidate], now: Date, rules: SleepingTabsPolicy
  ) -> [SleepingTabFacts] {
    var facts: [SleepingTabFacts] = []
    for candidate in candidates where !candidate.isLive {
      inactiveSince[candidate.id] = nil
    }
    for candidate in candidates where candidate.isLive {
      let stamp = inactiveSince[candidate.id] ?? now
      let item = makeFacts(candidate, lastActive: stamp)
      if rules.isExempt(item) {
        inactiveSince[candidate.id] = nil
      } else {
        inactiveSince[candidate.id] = stamp
      }
      facts.append(item)
    }
    return facts
  }

  private func makeFacts(_ candidate: Candidate, lastActive: Date) -> SleepingTabFacts {
    SleepingTabFacts(
      id: candidate.id, host: candidate.host, isPinned: candidate.isPinned,
      keepAlive: candidate.keepAlive, isVisible: candidate.isVisible,
      isPrivateActive: candidate.isPrivateActive,
      isPlaying: candidate.isPlaying || audible[candidate.id] == true,
      isCapturing: candidate.isCapturing || capturing[candidate.id] == true,
      formEdited: false, hasInspector: candidate.hasInspector,
      hasDeveloperTools: candidate.hasDeveloperTools,
      profileIsDownloading: candidate.profileIsDownloading, lastActive: lastActive)
  }
}
