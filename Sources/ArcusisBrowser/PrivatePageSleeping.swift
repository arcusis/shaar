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
    wakeNow(id)
  }

  func acceptSleep(_ id: UUID) {
    guard let store, store.session.page(forTabID: id) != nil else { return }
    if store.session.selectedPage?.tab.id == id || store.visiblePageIDs.contains(id) {
      wakeNow(id)
      return
    }
    store.noteTabSleeping(id)
  }

  private func wakeNow(_ id: UUID) {
    runtime.wakePrivateTabID(
      id.uuidString, windowID: windowID, contextID: contextID
    ) { [weak self] accepted in
      self?.store?.resolveWake(id, accepted: accepted)
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
      onSlept: { [weak self] id in self?.acceptSleep(id) })
  }

  func sleepingCandidates(in store: BrowserStore) -> [SleepingTabScheduler.Candidate] {
    let isProfileDownloading = profileIsDownloading
    let session = store.session
    var profileByTabID: [UUID: UUID] = [:]
    for space in session.spaces {
      for tab in space.tabs { profileByTabID[tab.id] = space.profileID }
    }
    let profileByFavoriteID = Dictionary(
      uniqueKeysWithValues: session.favorites.map { ($0.id, $0.profileID) })
    for page in session.favoritePages {
      if let profileID = profileByFavoriteID[page.favoriteID] {
        profileByTabID[page.tab.id] = profileID
      }
    }
    var downloadingByProfile: [UUID: Bool] = [:]
    return SleepingTabScheduler.candidates(
      in: store, liveTabs: liveTabs,
      isPlaying: { store.media.sessions[$0]?.isPlaying == true },
      isCapturing: { self.mediaAccess[$0]?.isCapturing == true },
      hasInspector: { self.inspectors[$0] != nil },
      hasDeveloperTools: { self.privateDeveloperTools.contains($0) },
      hasAgentConnection: { _ in false },
      profileIsDownloading: { id in
        guard let profile = profileByTabID[id] else { return false }
        if let isDownloading = downloadingByProfile[profile] { return isDownloading }
        let isDownloading = isProfileDownloading(profile)
        downloadingByProfile[profile] = isDownloading
        return isDownloading
      })
  }
}
