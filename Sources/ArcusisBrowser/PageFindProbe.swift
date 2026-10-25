import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

/// Searches authored fixture text through Chromium's find API, never page JavaScript.
@MainActor
final class PageFindProbe {
  let runtime: ARCChromiumRuntime
  let store: BrowserStore
  let root: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?

  init(runtime: ARCChromiumRuntime, store: BrowserStore, root: URL, phase: String) {
    self.runtime = runtime
    self.store = store
    self.root = root
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      let result = try await exercise()
      try writeReport(error: nil)
      return result
    } catch {
      store.dismissPageFind()
      try? writeReport(error: error)
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    let a = store.session.spaces[0]
    let b = store.session.spaces[1]
    let shared = store.session.spaces[2]
    let tabA = a.selectedTabID!
    let tabB = b.selectedTabID!
    for (tab, text) in [
      (tabA, "AlphaOnlyNeedle AlphaOnlyNeedle"), (tabB, "BetaOnlyNeedle"),
    ] {
      // This sets up disposable fixture contents only. Matching uses ArdiaCoreTab.find.
      let literal = String(data: try JSONEncoder().encode(text), encoding: .utf8)!
      guard
        await evaluate(
          tab,
          """
          (()=>{if(document.documentElement.dataset.arcusisFixture!=='v1')return null;
            let p=document.getElementById('find-profile');if(!p){p=document.createElement('p');
            p.id='find-profile';document.body.append(p);}p.textContent=\(literal);return {ready:true};})()
          """)?["ready"] as? Bool == true
      else { throw PageFindProbeFailure("Could not prepare authored find text.") }
    }
    store.perform(.space(a.id))
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    try await expectResult(count: 3, active: 1, "Chromium finds three authored text matches")
    store.movePageFind(forward: true)
    try await expectResult(count: 3, active: 2, "next match moves forward")
    store.movePageFind(forward: false)
    try await expectResult(count: 3, active: 1, "previous match moves backward")
    store.movePageFind(forward: false)
    try await expectResult(count: 3, active: 3, "previous match wraps to the last result")
    store.movePageFind(forward: true)
    try await expectResult(count: 3, active: 1, "next match wraps to the first result")
    store.updatePageFindQuery("orbitfindmarker")
    try await expectResult(count: 3, active: 1, "page search is case-insensitive")
    store.updatePageFindQuery("AlphaOnlyNeedle")
    store.updatePageFindQuery("OrbitFindMarker")
    store.updatePageFindQuery("MissingNeedle")
    try await expectResult(
      count: 0, active: 0, "rapid query replacement retains only the final result")
    store.updatePageFindQuery("AlphaOnlyNeedle")
    try await expectResult(count: 2, active: 1, "profile A finds only its current document text")
    guard let original = store.pageFind else {
      throw PageFindProbeFailure("Find session was lost.")
    }
    try await captureNative(width: 1200, name: "\(phase)-find-native.png")
    try await captureNative(width: 760, name: "\(phase)-find-compact.png")
    let picture: Data? = await withCheckedContinuation { continuation in
      runtime.captureProbeTabID(tabA.uuidString) { continuation.resume(returning: $0) }
    }
    guard let picture else { throw PageFindProbeFailure("Could not capture find highlights.") }
    try picture.write(to: root.appending(path: "\(phase)-find-page.png"), options: .atomic)

    store.perform(.space(b.id))
    try expect(store.pageFind == nil, "switching profiles closes find and discards its query")
    store.receiveFindResult(
      tabID: original.tabID, requestID: original.requestID, count: 2, active: 1, final: true)
    try expect(store.pageFind == nil, "late profile A results cannot revive closed find UI")
    try expect(
      !runtime.find(
        inTabID: tabA.uuidString, profileID: a.profileID.uuidString,
        requestID: UUID().uuidString, text: "AlphaOnlyNeedle", forward: true),
      "native bridge refuses a search in an inactive profile/tab")
    try expect(
      !runtime.find(
        inTabID: tabB.uuidString, profileID: a.profileID.uuidString,
        requestID: UUID().uuidString, text: "BetaOnlyNeedle", forward: true),
      "native bridge refuses a search with a mismatched profile")
    store.showPageFind()
    try expect(store.pageFind?.query == "", "profile B starts with an empty query")
    store.updatePageFindQuery("AlphaOnlyNeedle")
    try await expectResult(count: 0, active: 0, "profile B does not search profile A's page")
    store.updatePageFindQuery("BetaOnlyNeedle")
    try await expectResult(count: 1, active: 1, "profile B searches its own document")
    store.perform(.space(shared.id))
    try expect(
      shared.profileID == a.profileID && store.pageFind == nil,
      "an explicitly shared profile still clears find when its selected tab changes")
    store.showPageFind()
    store.updatePageFindQuery("AlphaOnlyNeedle")
    try await expectResult(
      count: 0, active: 0, "shared-profile search targets the selected document only")
    store.updatePageFindQuery("")
    try await Task.sleep(for: .milliseconds(200))
    try expect(
      store.pageFind?.query == "" && store.pageFind?.matchCount == nil,
      "clearing the query leaves no stale count or active search")

    store.perform(.space(a.id))
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    try await expectResult(count: 3, active: 1, "returning to A starts a new native search")
    let before = await evaluate(tabA, "({instance:window.arcusisInstance})")?["instance"] as? String
    runtime.reloadTabID(tabA.uuidString)
    var reloaded = false
    for _ in 0..<80 {
      if let state = await evaluate(
        tabA,
        "({instance:window.arcusisInstance,ready:document.documentElement.dataset.arcusisFixture==='v1'})"
      ), state["ready"] as? Bool == true, let instance = state["instance"] as? String,
        instance != before
      {
        reloaded = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(
      reloaded && store.pageFind == nil, "explicit reload closes find even at the same URL")
    store.showPageFind()
    try expect(store.pageFind?.query == "", "reloaded page does not inherit the previous query")
    store.dismissPageFind()
    return checks
  }

  private func expectResult(count: Int, active: Int, _ message: String) async throws {
    for _ in 0..<80 {
      if let result = store.pageFind, !result.searching,
        result.matchCount == count, result.activeMatch == active
      {
        try expect(true, message)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw PageFindProbeFailure("\(message): \(store.pageFind?.status ?? "find closed")")
  }

  private func evaluate(_ tab: UUID, _ expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: expression) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func captureNative(width: CGFloat, name: String) async throws {
    let height: CGFloat = width == 760 ? 520 : 780
    let host = NSHostingView(
      rootView: BrowserWindow(store: store).frame(width: width, height: height))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw PageFindProbeFailure("Could not render native find UI.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw PageFindProbeFailure("Could not encode native find UI.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PageFindProbeFailure(message) }
    checks.append(message)
  }

  private func writeReport(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "phase": phase, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Authored text searched through Chromium. Offscreen layout; live keyboard focus is unverified.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-find.json"), options: .atomic)
  }
}

private struct PageFindProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
