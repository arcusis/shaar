// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CoreFoundation
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
  let normalSession: BrowserSession
  let events: BrowserRuntimeEvents

  func run() async throws {
    let file = WorkspaceFile(
      url: root.appending(path: "private-multitab-workspace.json"),
      legacySessionURL: root.appending(path: "private-multitab-legacy.json"))
    _ = try BrowserWorkspaceStore(file: file, initialSession: normalSession)
    let workspace = try BrowserWorkspaceStore(file: file)
    let focus = Focus()
    let host = NativeBrowserHost(
      events: events, workspace: workspace, presentation: .hiddenProbe,
      usesPrimaryWindow: false, keyWindow: { focus.window },
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1080)] })
    defer { host.detach() }
    try host.restore()
    guard let focusedID = workspace.workspace.focusedWindowID,
      let normal = host.contexts[focusedID]
    else {
      throw Failure("Saved normal window was not restored.")
    }
    focus.window = normal.window
    guard host.canPerform(.newPrivateWindow),
      normal.store.session.selectedSpace.profileID.uuidString == sourceProfileID
    else { throw Failure("Saved normal profile cannot open a private window.") }
    host.perform(.newPrivateWindow)
    let owner = try await waitForOwner(host)
    guard !owner.window.isVisible else { throw Failure("Private fixture window became visible.") }
    let savedWorkspace = try Data(contentsOf: file.url)
    guard owner.store.isPrivate, owner.store.privatePage != nil,
      owner.store.faviconCache == nil, owner.store.engine == nil
    else {
      throw Failure("Private window did not use the isolated browser model.")
    }
    try await captureShell(owner, stage: "first-blank")
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
      try await captureShell(owner, stage: "tab-\(index)")
    }
    guard owner.store.tabs.count == 3 else { throw Failure("Private window lost a tab.") }
    owner.store.showPageFind()
    owner.store.updatePageFindQuery("OrbitFindMarker")
    var findMatches = 0
    for _ in 0..<100 {
      findMatches = owner.store.pageFind?.matchCount ?? 0
      if findMatches > 0 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    owner.store.dismissPageFind()
    guard findMatches > 0 else { throw Failure("Private Find did not return page matches.") }
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
        PrivateMultiTabEvidence.liveTabAudit(
          runtime.privateProbeAudit(forContextID: owner.contextID),
          tabCount: owner.store.tabs.count)
      {
        searchNavigated = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard searchNavigated else {
      throw Failure("Private address bar search did not navigate its live selected tab.")
    }
    let searchTabID = owner.store.selectedTabID
    var searchDocument: [String: Any]?
    for _ in 0..<Int(600 * ProbeTimeout.scale) {
      searchDocument = await evaluateSearch(searchTabID)
      if PrivateMultiTabEvidence.liveSearch(searchDocument, host: searchURL.host() ?? "") {
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let searchEvidence = searchDocument ?? [:]
    let searchData = try JSONSerialization.data(
      withJSONObject: searchEvidence, options: [.prettyPrinted, .sortedKeys])
    try searchData.write(to: root.appending(path: "\(phase)-private-search.json"), options: .atomic)
    guard PrivateMultiTabEvidence.liveSearch(searchEvidence, host: searchURL.host() ?? "") else {
      throw Failure("Private search did not render a live results document: \(searchEvidence).")
    }
    try await captureShell(owner, stage: "search")
    let privateSpace = owner.store.session.selectedSpaceID
    guard let folder = owner.store.createFolder(name: "Private folder", in: privateSpace),
      let firstID = UUID(uuidString: tabs[0]["tabID"] as? String ?? ""),
      owner.store.moveTab(firstID, from: privateSpace, to: privateSpace, folderID: folder)
    else { throw Failure("Private sidebar could not create a folder or move a tab into it.") }
    owner.store.splitSelectedTab()
    guard owner.store.selectedSplit != nil else {
      throw Failure("Private tabs could not use the shared split model.")
    }
    try await waitForSplitContainers(owner)
    try await captureShell(owner, stage: "split")
    try workspace.flushSaves()
    guard try Data(contentsOf: file.url) == savedWorkspace else {
      throw Failure("Private tabs, folder or split changed the saved normal workspace.")
    }
    let closed: Bool = await withCheckedContinuation { continuation in
      runtime.closePrivateWindowID(owner.windowID, contextID: owner.contextID) {
        continuation.resume(returning: $0)
      }
    }
    for _ in 0..<100 where !host.privateWindowOwners.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard closed && host.privateWindowOwners.isEmpty else {
      throw Failure("Private multitab window did not close cleanly.")
    }
    let report: [String: Any] = [
      "schema": 1, "phase": phase, "passed": true,
      "windowHidden": true, "openedThroughMenu": true, "savedNormalSession": true,
      "tabCount": 3, "tabs": tabs, "reselected": reselected,
      "addressSearchURL": searchURL.absoluteString,
      "privateFolderAndSplit": true, "workspaceUnchanged": true,
      "privateFindMatches": findMatches,
      "cleanupPassed": true,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-private-multitab.json"), options: .atomic)
  }

  private func waitForOwner(_ host: NativeBrowserHost) async throws -> PrivateBrowserHost.Owner {
    for _ in 0..<100 {
      if let owner = host.privateWindowOwners.first { return owner }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure("Private native window was not created.")
  }

  private func waitForTabs(_ store: BrowserStore, count: Int) async throws {
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

  private func evaluateSearch(_ tabID: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivacyProbeTabID(
        tabID,
        script:
          "({host:location.hostname,ready:document.readyState,title:document.title,textLength:document.body?.innerText.length??0,htmlLength:document.documentElement?.outerHTML.length??0})"
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
      PrivateMultiTabEvidence.liveTabAudit(audit, tabCount: owner.store.tabs.count)
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
    guard let light = PrivateMultiTabEvidence.lightSamples(bitmap) else {
      throw Failure("Private tab \(index) renderer has undecodable pixels.")
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

  private func captureShell(_ owner: PrivateBrowserHost.Owner, stage: String) async throws {
    owner.hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let native = runtime.view(
      forPrivateTabID: owner.store.selectedTabID,
      windowID: owner.windowID, contextID: owner.contextID)
    let containers = pageContainers(in: owner.hosting)
    let audit: [String: Any] = [
      "stage": stage,
      "containerCount": containers.count,
      "attachedContainerCount": containers.filter { $0.pageView?.superview === $0 }.count,
      "attachedPagesInWindowCount": containers.filter {
        $0.pageView?.superview === $0 && $0.pageView?.window === owner.window
      }.count,
      "visiblePagesInWindowCount": containers.filter {
        $0.pageView?.superview === $0 && $0.pageView?.window === owner.window
          && $0.pageView?.isHidden == false && !$0.isHidden
      }.count,
      "nativeViewPresent": native != nil,
      "nativeHidden": native?.isHidden ?? true,
      "nativeInWindow": native?.window === owner.window,
      "rawWindowSibling": native?.superview === owner.hosting.superview,
      "nativeFrame": NSStringFromRect(native?.frame ?? .zero),
      "containerFrames": containers.map { NSStringFromRect($0.frame) },
      "layerBacked": containers.map(\.wantsLayer),
      "attached": containers.contains {
        PrivateMultiTabEvidence.pageIsAttached(native, to: $0, retainedPage: $0.pageView)
      },
      "attachedInWindow": containers.contains {
        PrivateMultiTabEvidence.pageIsAttached(native, to: $0, retainedPage: $0.pageView)
          && native?.window === owner.window && $0.window === owner.window
      },
    ]
    let auditData = try JSONSerialization.data(
      withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
    try auditData.write(
      to: root.appending(path: "\(phase)-private-shell-\(stage).json"), options: .atomic)
    if stage == "first-blank", !PrivateMultiTabEvidence.blankShellAudit(audit) {
      throw Failure(
        "Blank private tab is not inside the SwiftUI page container: \(audit).")
    }
    guard !owner.window.isVisible,
      let bitmap = owner.hosting.bitmapImageRepForCachingDisplay(in: owner.hosting.bounds)
    else { throw Failure("Private shell capture became visible or has no bitmap.") }
    owner.hosting.cacheDisplay(in: owner.hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 4096
    else { throw Failure("Private shell capture was empty.") }
    try png.write(
      to: root.appending(path: "\(phase)-private-shell-\(stage).png"), options: .atomic)
    if stage == "split" {
      guard PrivateMultiTabEvidence.splitShellAudit(audit) else {
        throw Failure("Private split pages are not attached to their host containers: \(audit).")
      }
    } else if stage != "first-blank" {
      guard PrivateMultiTabEvidence.liveShellAudit(audit, stage: stage) else {
        throw Failure("Private page container is not layer-backed: \(audit).")
      }
    }
  }

  private func waitForSplitContainers(_ owner: PrivateBrowserHost.Owner) async throws {
    for _ in 0..<100 {
      owner.hosting.layoutSubtreeIfNeeded()
      if pageContainers(in: owner.hosting).count == 2 { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw Failure("Private split did not create two page containers.")
  }

  private func pageContainers(in view: NSView) -> [ChromiumPageContainerView] {
    let current = (view as? ChromiumPageContainerView).map { [$0] } ?? []
    return current + view.subviews.flatMap { pageContainers(in: $0) }
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  private final class Focus {
    weak var window: NSWindow?
  }
}

enum PrivateMultiTabEvidence {
  static func pageIsAttached(_ page: NSView?, to container: NSView, retainedPage: NSView?) -> Bool {
    guard let page, retainedPage === page else { return false }
    return page.superview === container
  }

  static func blankShellAudit(_ audit: [String: Any]) -> Bool {
    audit["nativeViewPresent"] as? Bool == true
      && liveShellAudit(audit, stage: "first-blank")
  }

  static func liveTabAudit(_ audit: [AnyHashable: Any]?, tabCount: Int) -> Bool {
    audit?["sourceIsRegular"] as? Bool == true
      && audit?["contextIsPrivate"] as? Bool == true
      && audit?["contextDistinct"] as? Bool == true
      && audit?["allWindowsUsePrivateActiveProfile"] as? Bool == true
      && audit?["allTabsInNativeProfileBrowser"] as? Bool == true
      && audit?["allWindowsDisplayOwnedWebContents"] as? Bool == true
      && integerEvidence(audit?["visibleNativeViewportCount"]) == 1
      && integerEvidence(audit?["tabCount"]) == tabCount
  }

  static func liveShellAudit(_ audit: [String: Any], stage: String) -> Bool {
    audit["stage"] as? String == stage
      && integerEvidence(audit["containerCount"]) == 1
      && audit["layerBacked"] as? [Bool] == [true]
      && audit["attached"] as? Bool == true
      && audit["attachedInWindow"] as? Bool == true
      && audit["nativeHidden"] as? Bool == false
      && audit["rawWindowSibling"] as? Bool == false
  }

  static func splitShellAudit(_ audit: [String: Any]) -> Bool {
    audit["stage"] as? String == "split"
      && integerEvidence(audit["containerCount"]) == 2
      && integerEvidence(audit["attachedContainerCount"]) == 2
      && integerEvidence(audit["attachedPagesInWindowCount"]) == 2
      && integerEvidence(audit["visiblePagesInWindowCount"]) == 2
      && audit["layerBacked"] as? [Bool] == [true, true]
      && audit["attached"] as? Bool == true
      && audit["attachedInWindow"] as? Bool == true
      && audit["nativeHidden"] as? Bool == false
      && audit["rawWindowSibling"] as? Bool == false
  }

  static func liveSearch(_ evidence: [String: Any]?, host: String) -> Bool {
    let ready = evidence?["ready"] as? String
    return evidence?["host"] as? String == host
      && (ready == "interactive" || ready == "complete")
      && (integerEvidence(evidence?["textLength"]) ?? 0) > 100
  }

  static func lightSamples(_ bitmap: NSBitmapImageRep) -> Int? {
    var light = 0
    for row in 1...8 {
      for column in 1...8 {
        let x = bitmap.pixelsWide * column / 9
        let y = bitmap.pixelsHigh * row / 9
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          return nil
        }
        if (color.redComponent + color.greenComponent + color.blueComponent) / 3 > 0.5 {
          light += 1
        }
      }
    }
    return light
  }

  private static func integerEvidence(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let encoding = String(cString: number.objCType)
    if encoding == "f" || encoding == "d" {
      return Int(exactly: number.doubleValue)
    }
    return Int(number.stringValue)
  }
}
