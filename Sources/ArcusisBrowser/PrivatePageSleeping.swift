// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Dispatch
import Foundation

extension PrivatePageSession {
  func suspendInactiveTabs(now: Date = Date()) {
    considerSleepingTabs(now: now, urgent: false)
  }

  func sleepForMemoryPressure(now: Date = Date()) {
    considerSleepingTabs(now: now, urgent: true)
  }

  func startSleepingTabWatch() {
    suspensionTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        guard let self, !self.isClosed else { return }
        self.suspendInactiveTabs()
      }
    }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      self?.sleepForMemoryPressure()
    }
    source.resume()
    memoryPressureSource = source
  }

  func stopSleepingTabWatch() {
    suspensionTask?.cancel()
    suspensionTask = nil
    memoryPressureSource?.cancel()
    memoryPressureSource = nil
  }

  func wakeIfSleeping(_ id: UUID) {
    guard store?.sleepingTabIDs.contains(id) == true else { return }
    runtime.wakePrivateTabID(
      id.uuidString, windowID: windowID, contextID: contextID
    ) { [weak self] accepted in
      if accepted { self?.store?.noteTabAwake(id) }
    }
  }

  func applyLifecycle(_ id: UUID, state: String, audible: Bool, capturing: Bool) {
    guard let store else { return }
    sleepingTabs.apply(
      state: state, audible: audible, capturing: capturing, id: id, store: store)
  }

  private func considerSleepingTabs(now: Date, urgent: Bool) {
    guard !isClosed, let store else { return }
    sleepingTabs.consider(
      sleepingCandidates(in: store), now: now, sleeping: store.sleepingTabIDs, urgent: urgent,
      probe: { [weak self] id, done in
        guard let self else {
          done(false)
          return
        }
        self.runtime.probePrivateTabLifecycle(
          forTabID: id.uuidString, windowID: self.windowID, contextID: self.contextID,
          completion: done)
      },
      evaluate: { [weak self] id, done in
        guard let self else {
          done(nil)
          return
        }
        self.runtime.evaluate(
          inPrivateTabID: id.uuidString, windowID: self.windowID, contextID: self.contextID,
          script: SleepingFormSignal.script, completion: done)
      },
      sleep: { [weak self] id, reason, done in
        guard let self else {
          done(false)
          return
        }
        self.runtime.sleepPrivateTabID(
          id.uuidString, windowID: self.windowID, contextID: self.contextID, reason: reason,
          completion: done)
      },
      fresh: { [weak self] in
        guard let self, let store = self.store else { return [] }
        return self.sleepingCandidates(in: store)
      },
      onSlept: { [weak store] id in store?.noteTabSleeping(id) })
  }

  private func sleepingCandidates(in store: BrowserStore) -> [SleepingTabScheduler.Candidate] {
    let visible = store.visiblePageIDs
    let selected = store.session.selectedPage?.tab.id
    var seen: Set<UUID> = []
    var candidates: [SleepingTabScheduler.Candidate] = []
    let tabs = store.session.spaces.flatMap(\.tabs) + store.session.favoritePages.map(\.tab)
    for tab in tabs where seen.insert(tab.id).inserted {
      candidates.append(
        SleepingTabScheduler.Candidate(
          id: tab.id, host: tab.url.host() ?? "", isPinned: tab.isPinned,
          keepAlive: tab.keepAlive, isVisible: visible.contains(tab.id),
          isPrivateActive: tab.id == selected,
          isPlaying: store.media.sessions[tab.id]?.isPlaying == true,
          isCapturing: false, hasInspector: inspectors[tab.id] != nil,
          hasDeveloperTools: shaarDevTools[tab.id] != nil, profileIsDownloading: false,
          isLive: liveTabs.contains(tab.id)))
    }
    return candidates
  }
}
