// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Dispatch
import Foundation

extension BrowserEngine {
  func suspendInactiveTabs(now: Date = Date()) {
    considerSleepingTabs(now: now, urgent: false)
  }

  func sleepForMemoryPressure(now: Date = Date()) {
    considerSleepingTabs(now: now, urgent: true)
  }

  func startSleepingTabWatch() {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      self?.sleepForMemoryPressure()
    }
    source.resume()
    memoryPressureSource = source
  }

  /// Runtime.evaluate replies off the main actor. A reply already on the main thread is delivered inline.
  private nonisolated static func deliverFormResult(
    _ result: String?, to done: @escaping @MainActor (String?) -> Void
  ) {
    let deliver: @MainActor @Sendable () -> Void = {
      done(result)
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated(deliver)
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  func wakeIfSleeping(_ id: UUID) {
    guard store?.sleepingTabIDs.contains(id) == true else { return }
    runtime.wakeTabID(id.uuidString) { [weak self] accepted in
      self?.store?.resolveWake(id, accepted: accepted)
    }
  }

  func acceptSleep(_ id: UUID) {
    guard let store, store.session.page(forTabID: id) != nil else { return }
    if store.session.selectedPage?.tab.id == id || store.visiblePageIDs.contains(id) {
      runtime.wakeTabID(id.uuidString) { [weak self] accepted in
        self?.store?.resolveWake(id, accepted: accepted)
      }
      return
    }
    store.noteTabSleeping(id)
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
        self.runtime.probeTabLifecycle(forTabID: id.uuidString, completion: done)
      },
      evaluate: { [weak self] id, done in
        guard let self else {
          done(nil)
          return
        }
        self.runtime.evaluate(
          inTabID: id.uuidString, script: SleepingFormSignal.script
        ) { result in
          Self.deliverFormResult(result, to: done)
        }
      },
      sleep: { [weak self] id, reason, done in
        guard let self else {
          done(false)
          return
        }
        self.runtime.sleepTabID(id.uuidString, reason: reason, completion: done)
      },
      fresh: { [weak self] in
        guard let self, let store = self.store else { return [] }
        return self.sleepingCandidates(in: store)
      },
      onSlept: { [weak self] id in self?.acceptSleep(id) })
  }

  func sleepingCandidates(in store: BrowserStore) -> [SleepingTabScheduler.Candidate] {
    let visible = store.visiblePageIDs
    let selected = store.session.selectedPage?.tab.id
    let tabs = store.session.spaces.flatMap(\.tabs) + store.session.favoritePages.map(\.tab)
    return SleepingTabScheduler.candidates(
      tabs: tabs, liveTabs: liveTabs, visible: visible,
      isPrivateActive: { store.isPrivate && $0 == selected },
      isPlaying: { store.media.sessions[$0]?.isPlaying == true },
      isCapturing: { self.mediaAccess[$0]?.isCapturing == true },
      hasInspector: { self.inspectors[$0] != nil },
      hasDeveloperTools: {
        self.developerModels[$0] != nil || self.shaarDevTools[$0] != nil
      },
      profileIsDownloading: { id in
        store.session.profileID(forTabID: id).map { profile in
          self.downloads.items(in: profile).contains { $0.state == .downloading }
        } ?? false
      })
  }
}
