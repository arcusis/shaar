import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

@MainActor
final class SavedTabCapacityProbe {
  private let runtime: ARCChromiumRuntime
  private let engine: BrowserEngine
  private let store: BrowserStore
  private let phase: String
  private let capacity: SavedTabCapacityFixture
  private var checks: [String] = []

  private struct NativeIdentity {
    let id: Int32
    let view: NSView
  }

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore,
    phase: String, capacity: SavedTabCapacityFixture
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.phase = phase
    self.capacity = capacity
  }

  func run() async throws -> [String] {
    let session = store.session
    let savedTabs = session.spaces.flatMap(\.tabs)
    guard savedTabs.count == SavedTabCapacityFixture.expectedTabCount,
      capacity.initialCheckpoint.matches(
        capacity.workspaceStore.workspace, ignoringTabTitles: true),
      session.profiles.count == SavedTabCapacityFixture.profileCount,
      session.spaces.count == SavedTabCapacityFixture.spaceCount,
      session.spaces.allSatisfy({ $0.tabs.count == SavedTabCapacityFixture.tabsPerSpace })
    else { throw SavedTabCapacityFailure("Saved capacity counts or metadata checkpoint mismatch.") }

    let initialSpace = session.selectedSpace
    guard let initialTabID = initialSpace.selectedTabID else {
      throw SavedTabCapacityFailure("Initial selected Space has no selected tab.")
    }
    let startupStarted = ProcessInfo.processInfo.systemUptime
    try await waitForDocument(initialTabID)
    let startupMilliseconds = (ProcessInfo.processInfo.systemUptime - startupStarted) * 1000
    let initialLiveCount = nativeLiveTabs(savedTabs)
    guard initialLiveCount == 1, runtime.nativeTabID(forID: initialTabID.uuidString) >= 0 else {
      throw SavedTabCapacityFailure(
        "Lazy startup materialized \(initialLiveCount) saved tabs; expected one.")
    }
    guard let initialView = runtime.view(forTabID: initialTabID.uuidString) else {
      throw SavedTabCapacityFailure("Initial saved tab has no native view.")
    }
    var nativeIdentities = [
      initialTabID: NativeIdentity(
        id: runtime.nativeTabID(forID: initialTabID.uuidString), view: initialView)
    ]
    _ = try assertNativeOwnership(savedTabs, visited: nativeIdentities)
    checks.append("\(phase) startup materialized only selected saved tab (1/1440)")

    var visitedTabs: [UUID: String] = [:]
    var visitedProfiles: Set<UUID> = []
    var storageOwners: Set<UUID> = []
    var maximumLiveCount = initialLiveCount
    var visitTimings: [[String: Any]] = []
    var visitDurationMilliseconds = 0.0
    let visitSpaces = Array(session.spaces.prefix(8))
    var revisitProofs: [[String: Any]] = []

    for space in visitSpaces {
      let visitStarted = ProcessInfo.processInfo.systemUptime
      guard let selected = space.selectedTabID else {
        throw SavedTabCapacityFailure("Saved Space has no selected tab.")
      }
      store.perform(.space(space.id))
      guard store.session.selectedSpaceID == space.id,
        store.session.selectedSpace.selectedTabID == selected,
        store.session.selectedSpace.profileID == space.profileID
      else { throw SavedTabCapacityFailure("Space switch changed saved identity or selection.") }
      try await waitForDocument(selected)
      var document = try await evaluate(selected)
      guard document["fixture"] as? String == "v1",
        let instance = document["instance"] as? String, !instance.isEmpty,
        runtime.nativeTabID(forID: selected.uuidString) >= 0
      else { throw SavedTabCapacityFailure("Visited saved tab did not load authored fixture.") }
      visitedTabs[selected] = instance
      visitedProfiles.insert(space.profileID)
      if nativeIdentities[selected] == nil {
        guard let view = runtime.view(forTabID: selected.uuidString) else {
          throw SavedTabCapacityFailure("Visited saved tab has no native view.")
        }
        nativeIdentities[selected] = NativeIdentity(
          id: runtime.nativeTabID(forID: selected.uuidString), view: view)
      }

      let storedOwner = document["localOwner"] as? String
      let storedCookie = document["cookieOwner"] as? String
      let sessionMarker = "\(phase):\(selected.uuidString)"
      if let previousMarker = document["sessionMarker"] as? String,
        previousMarker != sessionMarker
          && !(phase == "restart" && previousMarker == "initial:\(selected.uuidString)")
      {
        throw SavedTabCapacityFailure("Saved tab contains another tab's sessionStorage marker.")
      }
      if phase == "initial" {
        if storageOwners.insert(space.profileID).inserted {
          guard storedOwner == nil, storedCookie == nil else {
            throw SavedTabCapacityFailure("Fresh profile contains unexpected capacity storage.")
          }
          document = try await evaluate(
            selected,
            "(() => { document.cookie='saved-tab-capacity-owner=\(space.profileID.uuidString); Path=/; Max-Age=3600; SameSite=Lax'; localStorage.setItem('saved-tab-capacity-owner', '\(space.profileID.uuidString)'); sessionStorage.setItem('saved-tab-capacity-marker', '\(sessionMarker)'); const cookie=document.cookie.split('; ').find(value => value.startsWith('saved-tab-capacity-owner=')); return {fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookieOwner:cookie?.split('=')[1] ?? null,localOwner:localStorage.getItem('saved-tab-capacity-owner'),sessionMarker:sessionStorage.getItem('saved-tab-capacity-marker')}; })()"
          )
        } else if storedOwner != space.profileID.uuidString
          || storedCookie != space.profileID.uuidString
        {
          throw SavedTabCapacityFailure("Tabs in one profile do not share authored local storage.")
        }
        if document["sessionMarker"] as? String == nil {
          document = try await evaluate(
            selected,
            "(() => { sessionStorage.setItem('saved-tab-capacity-marker', '\(sessionMarker)'); const cookie=document.cookie.split('; ').find(value => value.startsWith('saved-tab-capacity-owner=')); return {fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookieOwner:cookie?.split('=')[1] ?? null,localOwner:localStorage.getItem('saved-tab-capacity-owner'),sessionMarker:sessionStorage.getItem('saved-tab-capacity-marker')}; })()"
          )
        }
      } else {
        if storedOwner != space.profileID.uuidString
          || storedCookie != space.profileID.uuidString
        {
          throw SavedTabCapacityFailure("Restart did not restore isolated profile storage.")
        }
        document = try await evaluate(
          selected,
          "(() => { sessionStorage.setItem('saved-tab-capacity-marker', '\(sessionMarker)'); const cookie=document.cookie.split('; ').find(value => value.startsWith('saved-tab-capacity-owner=')); return {fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookieOwner:cookie?.split('=')[1] ?? null,localOwner:localStorage.getItem('saved-tab-capacity-owner'),sessionMarker:sessionStorage.getItem('saved-tab-capacity-marker')}; })()"
        )
      }
      guard document["cookieOwner"] as? String == space.profileID.uuidString,
        document["localOwner"] as? String == space.profileID.uuidString,
        document["sessionMarker"] as? String == sessionMarker
      else {
        throw SavedTabCapacityFailure(
          "Profile cookie, localStorage, or seeded sessionStorage mismatch.")
      }

      let liveCount = try assertNativeOwnership(savedTabs, visited: nativeIdentities)
      maximumLiveCount = max(maximumLiveCount, liveCount)
      guard liveCount == visitedTabs.count else {
        throw SavedTabCapacityFailure(
          "Visiting \(visitedTabs.count) selected tabs materialized \(liveCount) saved tabs.")
      }
      let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - visitStarted) * 1000
      visitDurationMilliseconds += elapsedMilliseconds
      visitTimings.append([
        "spaceID": space.id.uuidString,
        "profileID": space.profileID.uuidString,
        "nativeTabID": runtime.nativeTabID(forID: selected.uuidString),
        "nativeLiveTabs": liveCount,
        "elapsedMilliseconds": elapsedMilliseconds,
      ])
      checks.append(
        "\(phase) Space \(space.id) loads under profile \(space.profileID); \(liveCount)/1440 selected tabs live"
      )
    }

    guard visitedTabs.count == 8, visitedProfiles.count == SavedTabCapacityFixture.profileCount,
      maximumLiveCount == 8
    else {
      throw SavedTabCapacityFailure("Bounded visit did not cover four profiles and eight Spaces.")
    }
    let visitedNativeTabIDs = visitSpaces.compactMap { space in
      space.selectedTabID.map { runtime.nativeTabID(forID: $0.uuidString) }
    }
    guard visitedNativeTabIDs.count == visitSpaces.count,
      visitedNativeTabIDs.allSatisfy({ $0 >= 0 }),
      Set(visitedNativeTabIDs).count == visitedNativeTabIDs.count
    else { throw SavedTabCapacityFailure("Visited saved tabs lack distinct native tab ownership.") }
    let liveAfterVisits = nativeLiveTabs(savedTabs)
    guard liveAfterVisits == visitSpaces.count else {
      throw SavedTabCapacityFailure("Unvisited saved tabs were unexpectedly materialized.")
    }
    let visitedTabIDs = Set(visitSpaces.compactMap(\.selectedTabID))
    let unvisitedTabs = savedTabs.filter { !visitedTabIDs.contains($0.id) }
    guard unvisitedTabs.allSatisfy({ runtime.nativeTabID(forID: $0.id.uuidString) == -1 }) else {
      throw SavedTabCapacityFailure("An unvisited saved tab acquired a native tab ID.")
    }

    for space in visitSpaces {
      guard let selected = space.selectedTabID,
        let expectedInstance = visitedTabs[selected],
        let originalNative = nativeIdentities[selected]
      else { throw SavedTabCapacityFailure("Revisit target lost native document identity.") }
      let beforeView = runtime.view(forTabID: selected.uuidString)
      let beforeNativeID = runtime.nativeTabID(forID: selected.uuidString)
      let beforeOwner = runtime.windowID(forTabID: selected.uuidString)
      let expectedOwner = engine.windowID
      let beforeDocument = try await evaluate(selected)
      guard beforeNativeID == originalNative.id, beforeView === originalNative.view,
        beforeOwner == expectedOwner,
        beforeDocument["instance"] as? String == expectedInstance,
        beforeDocument["cookieOwner"] as? String == space.profileID.uuidString,
        beforeDocument["localOwner"] as? String == space.profileID.uuidString,
        beforeDocument["sessionMarker"] as? String == "\(phase):\(selected.uuidString)"
      else { throw SavedTabCapacityFailure("Pre-revisit native ownership or document mismatch.") }

      store.perform(.space(space.id))
      guard store.session.selectedSpaceID == space.id,
        store.session.selectedSpace.selectedTabID == selected
      else { throw SavedTabCapacityFailure("Revisit changed saved Space or selected tab.") }
      try await waitForDocument(selected)

      let afterNativeID = runtime.nativeTabID(forID: selected.uuidString)
      let afterView = runtime.view(forTabID: selected.uuidString)
      let afterOwner = runtime.windowID(forTabID: selected.uuidString)
      let afterDocument = try await evaluate(selected)
      let expectedSessionMarker = "\(phase):\(selected.uuidString)"
      guard afterNativeID == originalNative.id, let afterView, afterView === originalNative.view,
        afterOwner == beforeOwner, afterOwner == expectedOwner,
        afterDocument["fixture"] as? String == "v1",
        afterDocument["instance"] as? String == expectedInstance,
        afterDocument["cookieOwner"] as? String == space.profileID.uuidString,
        afterDocument["localOwner"] as? String == space.profileID.uuidString,
        afterDocument["sessionMarker"] as? String == expectedSessionMarker
      else {
        throw SavedTabCapacityFailure(
          "Revisit replaced native identity, ownership, document, or storage.")
      }
      maximumLiveCount = max(
        maximumLiveCount, try assertNativeOwnership(savedTabs, visited: nativeIdentities))
      revisitProofs.append([
        "spaceID": space.id.uuidString,
        "tabID": selected.uuidString,
        "nativeTabIDPreserved": afterNativeID == beforeNativeID,
        "nativeViewPreserved": afterView === beforeView,
        "windowOwnerPreserved": afterOwner == beforeOwner,
        "documentInstancePreserved": afterDocument["instance"] as? String == expectedInstance,
        "cookiePreserved": afterDocument["cookieOwner"] as? String == space.profileID.uuidString,
        "localStoragePreserved": afterDocument["localOwner"] as? String
          == space.profileID.uuidString,
        "sessionStoragePreserved": afterDocument["sessionMarker"] as? String
          == expectedSessionMarker,
      ])
    }
    guard revisitProofs.count == 8, nativeLiveTabs(savedTabs) == visitSpaces.count,
      unvisitedTabs.allSatisfy({ runtime.nativeTabID(forID: $0.id.uuidString) == -1 })
    else { throw SavedTabCapacityFailure("All-eight revisit or unvisited-tab guard failed.") }
    checks.append("\(phase) revisited all eight Spaces with native and storage identity preserved")

    store.perform(.space(initialSpace.id))
    guard store.session.selectedSpaceID == capacity.initialCheckpoint.selectedSpaceID,
      let initialInstance = visitedTabs[initialTabID],
      try await evaluate(initialTabID)["instance"] as? String == initialInstance
    else {
      throw SavedTabCapacityFailure(
        "Visited document or initial selection did not survive switches.")
    }
    maximumLiveCount = max(
      maximumLiveCount, try assertNativeOwnership(savedTabs, visited: nativeIdentities))
    checks.append("\(phase) revisiting initial Space preserves selected document instance")

    if phase == "initial" {
      try capacity.recordExpectedRestartMetadata()
    } else if !capacity.initialCheckpoint.matches(
      capacity.workspaceStore.workspace, ignoringTabTitles: true)
    {
      throw SavedTabCapacityFailure(
        "Restart changed saved tab, Space, profile, pin, or folder metadata.")
    }

    let report: [String: Any] = [
      "schema": 1,
      "mode": SavedTabCapacityFixture.mode,
      "phase": phase,
      "runID": capacity.runID.uuidString,
      "scope": SavedTabCapacityFixture.scope,
      "passed": true,
      "workspaceSnapshot": capacity.workspaceURL.lastPathComponent,
      "identityCheckpoint": capacity.initialCheckpointURL.lastPathComponent,
      "selectedSpaceID": capacity.initialCheckpoint.selectedSpaceID.uuidString,
      "profileIDs": capacity.initialCheckpoint.profiles.map { $0.id.uuidString },
      "savedSpaceIDs": capacity.initialCheckpoint.spaces.map { $0.id.uuidString },
      "selectedTabIDs": capacity.initialCheckpoint.spaces.compactMap {
        $0.selectedTabID?.uuidString
      },
      "profileCount": session.profiles.count,
      "spaceCount": session.spaces.count,
      "savedTabs": savedTabs.count,
      "visitedSpaces": visitSpaces.count,
      "visitedProfiles": visitedProfiles.count,
      "initialNativeLiveTabs": initialLiveCount,
      "initialNativeTabID": runtime.nativeTabID(forID: initialTabID.uuidString),
      "peakNativeLiveTabs": maximumLiveCount,
      "liveTabsAfterVisits": liveAfterVisits,
      "unvisitedTabsMaterialized": liveAfterVisits - visitedTabs.count,
      "visitedNativeTabIDs": visitedNativeTabIDs,
      "initialDocumentWaitMilliseconds": startupMilliseconds,
      "visitDurationMilliseconds": visitDurationMilliseconds,
      "visitTimings": visitTimings,
      "revisitedSpaces": revisitProofs.count,
      "revisitProofs": revisitProofs,
      "checks": checks,
      "cleanup": NSNull(),
    ]
    try write(report)
    return checks
  }

  func recordCleanupAudit(engineClosed: Bool, primaryWindowClosed: Bool, routerClientCount: Int)
    throws
  {
    var report = try readReport()
    let cleanupPassed = engineClosed && primaryWindowClosed && routerClientCount == 0
    report["passed"] = (report["passed"] as? Bool == true) && cleanupPassed
    report["cleanup"] = [
      "mode": SavedTabCapacityFixture.mode,
      "phase": phase,
      "runID": capacity.runID.uuidString,
      "scope": SavedTabCapacityFixture.scope,
      "engineClosed": engineClosed,
      "primaryWindowClosed": primaryWindowClosed,
      "routerClientCount": routerClientCount,
      "passed": cleanupPassed,
    ]
    try write(report)
  }

  private func nativeLiveTabs(_ tabs: [BrowserTab]) -> Int {
    tabs.reduce(into: 0) { count, tab in
      if runtime.nativeTabID(forID: tab.id.uuidString) >= 0 { count += 1 }
    }
  }

  private func assertNativeOwnership(_ tabs: [BrowserTab], visited: [UUID: NativeIdentity]) throws
    -> Int
  {
    guard visited.count <= 8 else {
      throw SavedTabCapacityFailure("Capacity probe exceeded its eight-live-tab budget.")
    }
    for tab in tabs {
      let id = tab.id.uuidString
      if let original = visited[tab.id] {
        guard runtime.nativeTabID(forID: id) == original.id,
          runtime.view(forTabID: id) === original.view,
          runtime.windowID(forTabID: id) == engine.windowID
        else { throw SavedTabCapacityFailure("Visited native tab identity or owner changed.") }
      } else {
        guard runtime.nativeTabID(forID: id) < 0, runtime.view(forTabID: id) == nil,
          runtime.windowID(forTabID: id) == nil
        else { throw SavedTabCapacityFailure("Unvisited tab acquired native state.") }
      }
    }
    let liveCount = nativeLiveTabs(tabs)
    guard liveCount == visited.count else {
      throw SavedTabCapacityFailure("Native live tabs differ from the exact visited set.")
    }
    return liveCount
  }

  private func waitForDocument(_ id: UUID) async throws {
    for _ in 0..<100 {
      if runtime.nativeTabID(forID: id.uuidString) >= 0, engine.pages[id]?.loading == false,
        let value = try? await evaluate(id), value["fixture"] as? String == "v1"
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw SavedTabCapacityFailure("Saved tab did not load authored fixture: \(id).")
  }

  private func evaluate(
    _ id: UUID,
    _ script: String =
      "(() => { const cookie = document.cookie.split('; ').find(value => value.startsWith('saved-tab-capacity-owner=')); return {fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookieOwner:cookie?.split('=')[1] ?? null,localOwner:localStorage.getItem('saved-tab-capacity-owner'),sessionMarker:sessionStorage.getItem('saved-tab-capacity-marker')}; })()"
  ) async throws -> [String: Any] {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: id.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let json, let data = json.data(using: .utf8),
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw SavedTabCapacityFailure("Saved-tab fixture evaluation failed.") }
    return value
  }

  private func reportURL() -> URL {
    capacity.workspaceURL.deletingLastPathComponent()
      .appending(path: "\(phase)-saved-tab-capacity.json")
  }

  private func readReport() throws -> [String: Any] {
    guard
      let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL()))
        as? [String: Any],
      report["mode"] as? String == SavedTabCapacityFixture.mode,
      report["phase"] as? String == phase,
      report["runID"] as? String == capacity.runID.uuidString,
      report["scope"] as? String == SavedTabCapacityFixture.scope
    else { throw SavedTabCapacityFailure("Capacity report is missing or bound to another run.") }
    return report
  }

  private func write(_ report: [String: Any]) throws {
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: reportURL(), options: .atomic)
  }
}
