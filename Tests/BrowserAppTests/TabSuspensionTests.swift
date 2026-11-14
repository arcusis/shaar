// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite(.serialized) @MainActor
struct TabSuspensionTests {
  @Test func deinitializingEngineCancelsItsBackgroundSuspensionTask() throws {
    let tab = BrowserTab(url: URL(string: "https://engine-lifetime.example")!)
    var store: BrowserStore?
    var engine: BrowserEngine?
    do {
      let created = try makeEngine(tabs: [tab])
      store = created.0
      engine = created.1
    }
    let task = try #require(engine?.suspensionTask)
    weak var releasedEngine: BrowserEngine? = engine

    store?.engine = nil
    engine = nil

    #expect(releasedEngine == nil)
    #expect(task.isCancelled)
  }

  @Test func deinitializingPrivateSessionCancelsItsBackgroundSuspensionTask() throws {
    let tabID = UUID()
    var store: BrowserStore? = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: tabID))
    var session: PrivatePageSession? = nil
    if let store {
      session = PrivatePageSession(
        runtime: SuspensionTestRuntime(), contextID: "private-context",
        windowID: "private-window", firstTabID: tabID, store: store)
    }
    let task = try #require(session?.suspensionTask)
    session?.memoryPressureSource?.cancel()
    session?.memoryPressureSource = nil
    weak var releasedSession: PrivatePageSession? = session

    store?.privatePage = nil
    session = nil

    #expect(releasedSession == nil)
    #expect(task.isCancelled)
  }

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
    #expect(runtime.evaluatedScripts[0].contains("iframe"))
    #expect(runtime.evaluatedScripts[0].contains("shadowRoot"))
    #expect(!runtime.evaluatedScripts[0].contains("scrollX"))
    #expect(!runtime.evaluatedScripts[0].contains("scrollTo"))
  }

  @Test func sleepingCandidateDownloadLookupFocusedBenchmark() throws {
    let tabs = (0..<1_000).map { index in
      BrowserTab(url: URL(string: "https://tab-\(index).example")!)
    }
    let (store, engine, _) = try makeEngine(tabs: tabs)
    defer { engine.suspensionTask?.cancel() }
    let profileID = store.session.selectedSpace.profileID
    for index in 0..<1_000 {
      engine.downloads.changed(
        [
          "id": UUID().uuidString, "filename": "file-\(index)", "path": "",
          "url": "https://download.example/file", "state": DownloadState.downloading.rawValue,
          "paused": false, "dangerous": false, "offTheRecord": false,
          "received": 0.0, "total": -1.0, "startTime": Double(index),
        ], profileID: profileID)
    }

    let start = ContinuousClock.now
    let candidates = engine.sleepingCandidates(in: store)
    print("sleepingCandidateDownloadLookupFocusedBenchmark: \(start.duration(to: .now))")
    #expect(candidates.count == tabs.count)
    let allProfilesDownloading = candidates.allSatisfy { $0.profileIsDownloading }
    #expect(allProfilesDownloading)
  }

  @Test func privateSleepingCandidateDownloadLookupBenchmark() throws {
    let tabs = (0..<1_000).map { index in
      BrowserTab(url: URL(string: "https://private-tab-\(index).example")!)
    }
    let profile = BrowserProfile(name: "Private benchmark")
    let space = BrowserSpace(
      profileID: profile.id, name: "Private", symbol: "eye.slash", tint: .ocean,
      tabs: tabs, selectedTabID: tabs[0].id)
    let browserSession = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let store = BrowserStore(privateSession: browserSession)
    let runtime = SuspensionTestRuntime()
    var downloadCheckCount = 0
    let privateSession = PrivatePageSession(
      runtime: runtime, contextID: "benchmark-context", windowID: "benchmark-window",
      firstTabID: tabs[0].id, store: store, profileIsDownloading: { id in
        downloadCheckCount += 1
        return id == profile.id
      })
    defer {
      privateSession.suspensionTask?.cancel()
      privateSession.memoryPressureSource?.cancel()
    }
    var beforeSamples: [Duration] = []
    var afterSamples: [Duration] = []
    var beforeResolved = 0
    var afterResolved = 0
    for _ in 0..<5 {
      let beforeStart = ContinuousClock.now
      for tab in tabs where store.session.profileID(forTabID: tab.id) == profile.id {
        beforeResolved += 1
      }
      beforeSamples.append(beforeStart.duration(to: .now))
      let afterStart = ContinuousClock.now
      let candidates = privateSession.sleepingCandidates(in: store)
      for candidate in candidates where candidate.profileIsDownloading { afterResolved += 1 }
      afterSamples.append(afterStart.duration(to: .now))
      #expect(candidates.count == tabs.count)
    }
    #expect(beforeResolved == afterResolved && afterResolved == tabs.count * 5)
    #expect(downloadCheckCount == 5)
    let before = beforeSamples.sorted()[beforeSamples.count / 2]
    let after = afterSamples.sorted()[afterSamples.count / 2]
    print("privateSleepingCandidateDownloadLookup: before=\(before), after=\(after)")
    #expect(after < before * 0.5)
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

  @Test func aTabWithChromiumDevToolsOpenStaysAwake() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inspected = BrowserTab(url: URL(string: "https://inspected.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inspected])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inspected.id]
    runtime.devToolsOpenTabIDs.insert(inspected.id.uuidString)

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))

    #expect(runtime.slept.isEmpty)
    #expect(runtime.evaluatedScripts.isEmpty)
    #expect(store.sleepingTabIDs.isEmpty)
  }

  @Test func aDeveloperModelWithoutOpenToolsOrAgentCanSleep() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    let target = SiteControlTarget(
      tabID: inactive.id, profileID: store.session.selectedSpace.profileID, url: inactive.url)
    let model = engine.developerModel(for: target)
    #expect(!model.agentBridge.isConnected)
    #expect(runtime.devToolsView(forTabID: inactive.id.uuidString) == nil)

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))

    #expect(runtime.slept.map(\.0) == [inactive.id.uuidString])
    #expect(store.sleepingTabIDs == [inactive.id])
  }

  @Test func aTabWithAnAgentConnectionStaysAwake() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let connected = BrowserTab(url: URL(string: "https://connected.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, connected])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, connected.id]
    let target = SiteControlTarget(
      tabID: connected.id, profileID: store.session.selectedSpace.profileID, url: connected.url)
    let model = engine.developerModel(for: target)
    model.agentBridge.enable()
    #expect(model.agentBridge.isConnected)
    #expect(runtime.devToolsView(forTabID: connected.id.uuidString) == nil)

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))

    #expect(runtime.slept.isEmpty)
    #expect(store.sleepingTabIDs.isEmpty)
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

  @Test func aFailedCapabilityProbeCanSleepWhenALaterTickIsIdle() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    engine.sleepingTabs.capability = .unknown
    runtime.lifecycleCapable = false

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    #expect(engine.sleepingTabs.capability == .unknown)
    #expect(runtime.slept.isEmpty)

    runtime.lifecycleCapable = true
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(engine.sleepingTabs.capability == .capable)
    #expect(runtime.slept.map(\.0) == [inactive.id.uuidString])
    #expect(store.sleepingTabIDs == [inactive.id])
  }

  @Test func anIdleTickDuringCapabilityProbeIsRetriedWithItsNewTimestamp() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    engine.sleepingTabs.capability = .unknown
    runtime.holdLifecycleProbe = true

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(engine.sleepingTabs.capability == .probing)
    #expect(runtime.slept.isEmpty)

    runtime.deliverHeldLifecycleProbe()

    #expect(engine.sleepingTabs.capability == .capable)
    #expect(runtime.slept.map(\.0) == [inactive.id.uuidString])
    #expect(store.sleepingTabIDs == [inactive.id])
  }

  @Test func newlyExemptTabsStayAwakeWhenHeldProbeResolves() throws {
    for change in ["playing", "pinned", "devtools"] {
      let active = BrowserTab(url: URL(string: "https://active.example")!)
      let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
      let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
      defer { engine.suspensionTask?.cancel() }
      engine.liveTabs = [active.id, inactive.id]
      engine.sleepingTabs.capability = .unknown
      runtime.holdLifecycleProbe = true

      let start = Date(timeIntervalSince1970: 1_800_000_000)
      engine.suspendInactiveTabs(now: start)
      engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
      #expect(engine.sleepingTabs.capability == .probing)

      switch change {
      case "playing":
        store.media.update(inactive.id, state: MediaSessionState(playbackState: .playing))
      case "pinned":
        store.togglePin(inactive.id)
      default:
        runtime.devToolsOpenTabIDs.insert(inactive.id.uuidString)
      }
      runtime.deliverHeldLifecycleProbe()

      #expect(runtime.slept.isEmpty, "\(change) tab slept after capability probe")
      #expect(store.sleepingTabIDs.isEmpty)
    }
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

  @Test func memoryPressureSkipsTabsThatAreAlreadySleeping() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let background = (0..<6).map { index in
      BrowserTab(url: URL(string: "https://tab-\(index).example")!)
    }
    let (store, engine, runtime) = try makeEngine(tabs: [active] + background)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = Set(([active] + background).map(\.id))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    store.noteTabSleeping(background[0].id)
    store.noteTabSleeping(background[1].id)
    engine.sleepForMemoryPressure(now: start.addingTimeInterval(1))
    #expect(runtime.slept.map(\.0) == background[2...5].map(\.id.uuidString))
    #expect(runtime.slept.allSatisfy { $0.1 == "urgent" })
    #expect(store.sleepingTabIDs == Set(background.map(\.id)))
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

  @Test func aFailedWakeClearsTheSelectedSleepingTab() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(store.sleepingTabIDs == [inactive.id])
    runtime.wakeAccepted = false
    engine.wakeIfSleeping(inactive.id)
    #expect(runtime.woke == [inactive.id.uuidString])
    #expect(store.sleepingTabIDs == [inactive.id])
    store.perform(.tab(space: store.session.selectedSpaceID, tab: inactive.id))
    engine.reconcile()
    #expect(store.sleepingTabIDs.isEmpty)
  }

  @Test func aClosedTabCannotBeMarkedSleeping() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = [active.id, inactive.id]
    runtime.holdSleepCompletion = true
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.slept.map(\.0) == [inactive.id.uuidString])
    #expect(store.sleepingTabIDs.isEmpty)
    store.session.closeTab(inactive.id)
    runtime.deliverHeldSleep()
    #expect(store.sleepingTabIDs.isEmpty)
    store.noteTabSleeping(inactive.id)
    engine.sleepingTabs.apply(
      state: "discarded", audible: false, capturing: false, id: inactive.id, store: store)
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

  @Test func aPrivateTabThatIsCapturingStaysAwake() throws {
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
    session.noteMediaAccess(first, camera: true, microphone: false, screen: false)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    session.suspendInactiveTabs(now: start)
    session.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.privateSlept.isEmpty)
    #expect(store.sleepingTabIDs.isEmpty)
    #expect(session.liveTabs.contains(first))
    #expect(session.liveTabs.contains(background))
  }

  @Test func aPrivateProfileWithAnActiveDownloadKeepsTabsAwake() throws {
    let first = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: first))
    let runtime = SuspensionTestRuntime()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context", windowID: "private-window",
      firstTabID: first, store: store, profileIsDownloading: { _ in true })
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

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    session.sleepForMemoryPressure(now: start)
    #expect(runtime.privateSlept.isEmpty)
    #expect(store.sleepingTabIDs.isEmpty)
    #expect(session.liveTabs.contains(background))
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
  nonisolated(unsafe) var holdLifecycleProbe = false
  nonisolated(unsafe) var wakeAccepted = true
  nonisolated(unsafe) var holdSleepCompletion = false
  nonisolated(unsafe) var devToolsOpenTabIDs: Set<String> = []
  nonisolated(unsafe) var agentBridgeEnabledTabIDs: Set<String> = []
  nonisolated(unsafe) var heldLifecycleProbe: (@MainActor @Sendable (Bool) -> Void)?
  nonisolated(unsafe) var heldSleep: (@MainActor @Sendable (Bool) -> Void)?

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

  override func devToolsView(forTabID tabID: String) -> NSView? {
    let isOpen = devToolsOpenTabIDs.contains(tabID)
    return MainActor.assumeIsolated { isOpen ? NSView() : nil }
  }

  override func agentBridgeRequest(
    _ operation: UInt, forTabID tabID: String, profileID: String, windowID: String,
    completion: @escaping @MainActor ([String: Any]?, Error?) -> Void
  ) {
    if operation == UInt(AgentBridgeOperation.enable.rawValue) {
      agentBridgeEnabledTabIDs.insert(tabID)
    } else if operation == UInt(AgentBridgeOperation.disable.rawValue) {
      agentBridgeEnabledTabIDs.remove(tabID)
    }
    guard agentBridgeEnabledTabIDs.contains(tabID) else {
      completion(["schemaVersion": 1, "enabled": false, "connectionCount": 0], nil)
      return
    }
    var response: [String: Any] = [
      "schemaVersion": 1, "enabled": true, "port": 9222,
      "wsEndpoint": "ws://127.0.0.1:9222/devtools/browser/id",
      "connectionCount": 1,
    ]
    if operation == UInt(AgentBridgeOperation.enable.rawValue) {
      response["token"] = String(repeating: "a", count: 43)
    }
    completion(response, nil)
  }

  override func discardTabID(_ tabID: String) {
    discardedTabIDs.append(tabID)
  }

  override func probeTabLifecycle(
    forTabID tabID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    if holdLifecycleProbe {
      heldLifecycleProbe = completion
      return
    }
    finish(lifecycleCapable, completion)
  }

  func deliverHeldLifecycleProbe(_ capable: Bool = true) {
    let completion = heldLifecycleProbe
    heldLifecycleProbe = nil
    guard let completion else { return }
    finish(capable, completion)
  }

  override func sleepTabID(
    _ tabID: String, reason: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    slept.append((tabID, reason))
    if holdSleepCompletion {
      heldSleep = completion
      return
    }
    finish(true, completion)
  }

  func deliverHeldSleep(_ accepted: Bool = true) {
    let completion = heldSleep
    heldSleep = nil
    guard let completion else { return }
    finish(accepted, completion)
  }

  override func wakeTabID(
    _ tabID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    woke.append(tabID)
    finish(wakeAccepted, completion)
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
