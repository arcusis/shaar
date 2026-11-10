// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite(.serialized) @MainActor
struct TabSuspensionTests {
  @Test func idleTabsAreDiscardedWithoutClosingOrRestoringScroll() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let pinned = BrowserTab(url: URL(string: "https://pinned.example")!, isPinned: true)
    let playing = BrowserTab(url: URL(string: "https://playing.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, pinned, playing, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = Set([active, pinned, playing, inactive].map(\.id))
    store.media.update(playing.id, state: MediaSessionState(playbackState: .playing))

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    #expect(runtime.evaluatedScripts.isEmpty)
    #expect(runtime.slept.isEmpty)

    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.slept.map(\.0) == [inactive.id.uuidString])
    #expect(runtime.slept.map(\.1) == ["proactive"])
    #expect(runtime.discardedTabIDs.isEmpty)
    #expect(engine.liveTabs.contains(inactive.id))
    #expect(engine.liveTabs.contains(pinned.id))
    #expect(engine.liveTabs.contains(playing.id))
    #expect(store.sleepingTabIDs == [inactive.id])
    #expect(runtime.evaluatedScripts.count == 1)
    #expect(runtime.evaluatedScripts[0].contains("edited"))
    #expect(!runtime.evaluatedScripts[0].contains("scrollX"))
    #expect(!runtime.evaluatedScripts[0].contains("scrollTo"))
  }

  @Test func anEditedFormStaysAwake() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let edited = BrowserTab(url: URL(string: "https://edited.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, edited])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, edited.id]
    runtime.evaluationResult = "{\"edited\":true}"
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.slept.isEmpty)
    #expect(runtime.evaluatedScripts.count == 1)
    #expect(store.sleepingTabIDs.isEmpty)
    #expect(engine.liveTabs.contains(edited.id))
  }

  @Test func editedFormsKeepAliveAndDownloadsStayAwake() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let kept = BrowserTab(url: URL(string: "https://kept.example")!, keepAlive: true)
    let edited = BrowserTab(url: URL(string: "https://edited.example")!)
    let downloading = BrowserTab(url: URL(string: "https://download.example")!)
    let (store, engine, runtime) = try makeEngine(
      tabs: [active, kept, edited, downloading])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = Set([active.id, kept.id, edited.id, downloading.id])
    runtime.evaluationResult = "{\"edited\":true}"
    engine.downloads.changed(
      [
        "id": UUID().uuidString, "filename": "sample.zip", "path": "",
        "url": "https://download.example/sample.zip",
        "state": "downloading", "paused": false, "dangerous": false, "offTheRecord": false,
        "received": 0.0, "total": 100.0, "startTime": 1.0,
      ], profileID: store.session.selectedSpace.profileID)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.slept.isEmpty)
    #expect(runtime.evaluatedScripts.isEmpty)
    #expect(runtime.discardedTabIDs.isEmpty)
    #expect(engine.liveTabs.contains(edited.id))
    #expect(engine.liveTabs.contains(downloading.id))
  }

  @Test func anIncapableEngineDoesNotSleepOrClose() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    engine.sleepingTabs.capability = .unknown
    runtime.lifecycleCapable = false
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.slept.isEmpty)
    #expect(runtime.discardedTabIDs.isEmpty)
    #expect(store.sleepingTabIDs.isEmpty)
    #expect(engine.liveTabs.contains(inactive.id))
  }

  @Test func neverSleepHostsStayAwake() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let mail = BrowserTab(url: URL(string: "https://www.mail.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, mail])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, mail.id]
    engine.sleepingTabs.policy = {
      SleepingTabsPolicy(enabled: true, timeout: 5 * 60, neverSleepHosts: ["mail.example"])
    }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.slept.isEmpty)
    #expect(store.sleepingTabIDs.isEmpty)
    #expect(runtime.evaluatedScripts.isEmpty)
  }

  @Test func memoryPressureDiscardsTheOldestEligibleTabs() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let background = (0..<6).map { index in
      BrowserTab(url: URL(string: "https://tab-\(index).example")!)
    }
    let (store, engine, runtime) = try makeEngine(tabs: [active] + background)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = Set(([active] + background).map(\.id))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.sleepForMemoryPressure(now: start.addingTimeInterval(1))
    #expect(runtime.slept.map(\.0) == background.prefix(4).map(\.id.uuidString))
    #expect(runtime.slept.allSatisfy { $0.1 == "urgent" })
    #expect(runtime.discardedTabIDs.isEmpty)
    #expect(store.sleepingTabIDs == Set(background.prefix(4).map(\.id)))
    #expect(engine.liveTabs.isSuperset(of: store.sleepingTabIDs))
  }

  @Test func selectingASleepingTabWakesIt() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(store.sleepingTabIDs == [inactive.id])
    store.perform(.tab(space: store.session.selectedSpaceID, tab: inactive.id))
    engine.reconcile()
    #expect(runtime.woke == [inactive.id.uuidString])
    #expect(store.sleepingTabIDs.isEmpty)
  }

  @Test func aLifecycleEventMarksAndClearsTheSleepingTab() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    #expect(engine.events.router.bindTab(inactive.id.uuidString, windowID: engine.windowID))
    runtime.onTabLifecycle?(inactive.id.uuidString, "discarded", false, false)
    #expect(store.sleepingTabIDs == [inactive.id])
    runtime.onTabLifecycle?(inactive.id.uuidString, "discarded", true, false)
    #expect(store.sleepingTabIDs.isEmpty)
    runtime.onTabLifecycle?(inactive.id.uuidString, "frozen", false, false)
    #expect(store.sleepingTabIDs == [inactive.id])
    runtime.onTabLifecycle?(inactive.id.uuidString, "active", false, false)
    #expect(store.sleepingTabIDs.isEmpty)
  }

  @Test func aPrivateBackgroundTabSleepsAndTheSelectedTabStaysAwake() throws {
    let first = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: first))
    let runtime = SuspensionTestRuntime()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context", windowID: "private-window",
      firstTabID: first, store: store)
    defer { session.suspensionTask?.cancel() }
    session.sleepingTabs.policy = {
      SleepingTabsPolicy(enabled: true, timeout: 5 * 60, neverSleepHosts: [])
    }
    session.sleepingTabs.capability = .capable
    session.memoryPressureSource?.cancel()
    session.memoryPressureSource = nil
    let opened = store.session.open(URL(string: "https://background.example")!)
    let background = try #require(opened)
    session.reconcile()
    #expect(session.liveTabs.contains(first))
    #expect(session.liveTabs.contains(background))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    session.suspendInactiveTabs(now: start)
    session.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.privateSlept.map(\.0) == [first.uuidString])
    #expect(runtime.privateSlept.map(\.1) == ["proactive"])
    #expect(store.sleepingTabIDs == [first])
    store.session.selectTab(first, in: store.session.selectedSpaceID)
    session.reconcile()
    #expect(runtime.privateWoke == [first.uuidString])
    #expect(store.sleepingTabIDs.isEmpty)
  }

  private func makeEngine(tabs: [BrowserTab]) throws -> (
    BrowserStore, BrowserEngine, SuspensionTestRuntime
  ) {
    let profile = BrowserProfile(name: "Suspension test")
    let space = BrowserSpace(
      profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
      tabs: tabs, selectedTabID: tabs[0].id)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let store = BrowserStore(session: session)
    let runtime = SuspensionTestRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store)
    engine.sleepingTabs.policy = {
      SleepingTabsPolicy(enabled: true, timeout: 5 * 60, neverSleepHosts: [])
    }
    engine.sleepingTabs.capability = .capable
    engine.memoryPressureSource?.cancel()
    engine.memoryPressureSource = nil
    return (store, engine, runtime)
  }
}

private final class SuspensionTestRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var evaluatedScripts: [String] = []
  nonisolated(unsafe) var discardedTabIDs: [String] = []
  nonisolated(unsafe) var slept: [(String, String)] = []
  nonisolated(unsafe) var woke: [String] = []
  nonisolated(unsafe) var privateSlept: [(String, String)] = []
  nonisolated(unsafe) var privateWoke: [String] = []
  nonisolated(unsafe) var evaluationResult = "{\"edited\":false}"
  nonisolated(unsafe) var lifecycleCapable = true

  override func evaluate(
    inTabID tabID: String, script: String,
    completion: @escaping @Sendable (String?) -> Void
  ) {
    evaluatedScripts.append(script)
    completion(evaluationResult)
  }

  override func evaluate(
    inPrivateTabID tabID: String, windowID: String, contextID: String, script: String,
    completion: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    evaluatedScripts.append(script)
    finish(evaluationResult, completion)
  }

  override func windowID(forTabID tabID: String) -> String? { primaryWindowID }

  override func discardTabID(_ tabID: String) {
    discardedTabIDs.append(tabID)
  }

  override func probeTabLifecycle(
    forTabID tabID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    finish(lifecycleCapable, completion)
  }

  override func sleepTabID(
    _ tabID: String, reason: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    slept.append((tabID, reason))
    finish(true, completion)
  }

  override func wakeTabID(
    _ tabID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    woke.append(tabID)
    finish(true, completion)
  }

  override func probePrivateTabLifecycle(
    forTabID tabID: String, windowID: String, contextID: String,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    finish(lifecycleCapable, completion)
  }

  override func sleepPrivateTabID(
    _ tabID: String, windowID: String, contextID: String, reason: String,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    privateSlept.append((tabID, reason))
    finish(true, completion)
  }

  override func wakePrivateTabID(
    _ tabID: String, windowID: String, contextID: String,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    privateWoke.append(tabID)
    finish(true, completion)
  }

  /// The scheduler is already on the main actor. Deliver inline so a second pass sees the reply.
  private func finish<T: Sendable>(_ value: T, _ completion: @escaping @MainActor (T) -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { completion(value) }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { completion(value) } }
    }
  }

  override func openPrivateTabID(
    _ tabID: String, windowID: String, contextID: String, url: String
  ) throws {}

  override func selectPrivateTabID(_ tabID: String, windowID: String, contextID: String) -> Bool {
    true
  }

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    completion(nil)
  }

  override func openTabID(_ tabID: String, profileID: String, windowID: String, url: String) throws
  {}

  override func extensions(forProfileID profileID: String) -> [[String: Any]] { [] }
}
