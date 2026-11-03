// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CryptoKit
import Foundation

@testable import ArcusisBrowser

/// Exercises the product's private tab owner and renderer in an un-ordered native window.
@MainActor
struct PrivateMultiTabProbe {
  let runtime: ARCChromiumRuntime
  let root: URL
  let fixture: URL
  let phase: String
  let sourceProfileID: String

  func run() async throws {
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()
    defer { host.detach() }
    try host.openWindow()
    let owner = try await waitForOwner(host)
    guard !owner.window.isVisible else { throw Failure("Private fixture window became visible.") }
    var tabs: [[String: Any]] = []
    for index in 0..<3 {
      if index > 0 {
        owner.store.openTab()
        try await waitForTabs(owner.store, count: index + 1)
      }
      let tabID = owner.store.selectedTabID
      let url = fixture.appending(path: "private-multitab-\(phase)-\(index)")
      owner.store.navigate(url.absoluteString)
      owner.store.confirmHTTP(useHTTPS: false)
      try await waitForDocument(owner, tabID: tabID, path: url.path)
      tabs.append(try await capture(owner, tabID: tabID, index: index, visit: "opened"))
    }
    guard owner.store.tabs.count == 3 else { throw Failure("Private window lost a tab.") }
    var reselected: [[String: Any]] = []
    for index in (0..<3).reversed() {
      let tabID = tabs[index]["tabID"] as! String
      if owner.store.selectedTabID != tabID { owner.store.selectTab(tabID) }
      let path = fixture.appending(path: "private-multitab-\(phase)-\(index)").path
      try await waitForDocument(owner, tabID: tabID, path: path)
      reselected.append(
        try await capture(owner, tabID: tabID, index: index, visit: "reselected"))
    }
    owner.store.showCommand()
    owner.store.commandQuery = "shaar private smoke search"
    owner.store.submitCommand()
    let searchURL = NavigationInput.destination(
      for: "shaar private smoke search", searchEngine: owner.store.searchEngine)!
    var searchNavigated = false
    for _ in 0..<100 {
      if owner.store.selectedTab?.url == searchURL.absoluteString,
        runtime.privateProbeAudit(forContextID: owner.contextID)?[
          "allWindowsDisplayOwnedWebContents"] as? Bool == true
      {
        searchNavigated = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard searchNavigated else {
      throw Failure("Private address bar search did not navigate its live selected tab.")
    }
    let closed: Bool = await withCheckedContinuation { continuation in
      runtime.closePrivateWindowID(owner.windowID, contextID: owner.contextID) {
        continuation.resume(returning: $0)
      }
    }
    for _ in 0..<100 where host.windowCount != 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard closed && host.windowCount == 0 else {
      throw Failure("Private multitab window did not close cleanly.")
    }
    let report: [String: Any] = [
      "schema": 1, "phase": phase, "passed": true,
      "windowHidden": true, "tabCount": 3, "tabs": tabs, "reselected": reselected,
      "addressSearchURL": searchURL.absoluteString,
      "cleanupPassed": true,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-private-multitab.json"), options: .atomic)
  }

  private func waitForOwner(_ host: PrivateBrowserHost) async throws -> PrivateBrowserHost.Owner {
    for _ in 0..<100 {
      if let owner = host.ownedWindows.first { return owner }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure("Private native window was not created.")
  }

  private func waitForTabs(_ store: PrivateBrowserStore, count: Int) async throws {
    for _ in 0..<100 {
      if store.tabs.count == count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure("Private tab count did not reach \(count).")
  }

  private func waitForDocument(
    _ owner: PrivateBrowserHost.Owner, tabID: String, path: String
  ) async throws {
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      let tab = owner.store.tabs.first { $0.id == tabID }
      if tab?.loading == false, tab?.url.contains(path) == true,
        let result = await evaluate(tabID), result["path"] as? String == path,
        result["fixture"] as? String == "v1", result["instance"] is String
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let tab = owner.store.tabs.first { $0.id == tabID }
    let result = await evaluate(tabID)
    throw Failure(
      "Private tab \(tabID) did not load authored document \(path): selected=\(owner.store.selectedTabID), tab=\(String(describing: tab)), evaluation=\(String(describing: result))."
    )
  }

  private func evaluate(_ tabID: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivacyProbeTabID(
        tabID,
        script:
          "({path:location.pathname,fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance})"
      ) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func capture(
    _ owner: PrivateBrowserHost.Owner, tabID: String, index: Int, visit: String
  ) async throws -> [String: Any] {
    var ready = false
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      ready = runtime.privateProbeCaptureIsReady(
        forTabID: tabID, windowID: owner.windowID, contextID: owner.contextID)
      if ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let audit = runtime.privateProbeAudit(forContextID: owner.contextID)
    guard ready,
      let audit,
      audit["allTabsInNativeProfileBrowser"] as? Bool == true,
      audit["allWindowsDisplayOwnedWebContents"] as? Bool == true,
      audit["visibleNativeViewportCount"] as? Int == 1,
      audit["tabCount"] as? Int == owner.store.tabs.count
    else {
      throw Failure(
        "Private tab \(index) has no live selected WebContents: ready=\(ready), audit=\(String(describing: audit))."
      )
    }
    let (data, error): (Data?, String?) = await withCheckedContinuation { continuation in
      runtime.capturePrivateProbeTabID(
        tabID, windowID: owner.windowID,
        contextID: owner.contextID
      ) { data, error in
        continuation.resume(returning: (data, error))
      }
    }
    guard let data, error == nil, data.count > 4096,
      let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 100,
      bitmap.pixelsHigh > 100
    else {
      throw Failure("Private tab \(index) renderer capture failed: \(error ?? "empty PNG").")
    }
    var light = 0
    for row in 1...8 {
      for column in 1...8 {
        let x = bitmap.pixelsWide * column / 9
        let y = bitmap.pixelsHigh * row / 9
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          throw Failure("Private tab \(index) renderer has undecodable pixels.")
        }
        if (color.redComponent + color.greenComponent + color.blueComponent) / 3 > 0.5 {
          light += 1
        }
      }
    }
    guard light >= 48 else { throw Failure("Private tab \(index) rendered a dark or black page.") }
    let filename = "\(phase)-private-multitab-\(index)-\(visit).png"
    try data.write(to: root.appending(path: filename), options: .atomic)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return [
      "tabID": tabID, "index": index,
      "path": fixture.appending(path: "private-multitab-\(phase)-\(index)").path,
      "capture": filename, "sha256": digest, "lightSamples": light,
    ]
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
