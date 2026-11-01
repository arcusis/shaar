// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@testable import ArcusisBrowser

private struct WorkspaceProbeIdentity: Codable {
  let first: UUID
  let second: UUID
  let alpha: UUID
  let beta: UUID
  let firstPin: UUID
  let secondPin: UUID
  let firstOrdinary: UUID
  let betaTab: UUID
  let closed: UUID
  var firstDocument: String?
  var secondDocument: String?
}

/// Uses the managed workspace writer and actual window clients; the production host is not involved.
@MainActor
final class WorkspaceProbe {
  let primary: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var runtime: ARCChromiumRuntime { primary.runtime }
  private var checks: [String] = []
  private var hosts: [NSHostingView<BrowserWindow>] = []
  private var clients: [UUID: BrowserEngine] = [:]

  init(primary: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.primary = primary
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    let bases = Array(store.session.spaces.prefix(3))
    let mainSession = store.session
    let a = bases[0].profileID
    let b = bases[1].profileID
    var originals: [UUID: NSDictionary] = [:]
    for base in bases {
      originals[base.selectedTabID!] = try await document(base.selectedTabID!) as NSDictionary
    }
    let file = WorkspaceFile(
      url: root.appending(path: "probe-workspace.json"),
      legacySessionURL: root.appending(path: "probe-workspace-legacy.json"))
    let identityFile = root.appending(path: "workspace-identities.json")
    if phase == "initial" {
      let folder = BrowserFolder(name: "Company tools", isCollapsed: true)
      let pin = BrowserTab(
        url: fixture.appending(path: "workspace-pin-original"), isPinned: true, folderID: folder.id)
      let alpha = BrowserSpace(
        profileID: a, name: "Workspace alpha", symbol: "house", tint: .ocean,
        tabs: [pin, BrowserTab(url: fixture.appending(path: "workspace-alpha-live"))],
        folders: [folder])
      let beta = BrowserSpace(
        profileID: b, name: "Workspace beta", symbol: "briefcase", tint: .rose,
        tabs: [BrowserTab(url: fixture.appending(path: "workspace-beta-live"))])
      var session = try BrowserSession(
        profiles: store.session.profiles.filter { [a, b].contains($0.id) }, spaces: [alpha, beta],
        selectedSpaceID: alpha.id)
      session.selectTab(alpha.tabs[1].id, in: alpha.id)
      try SessionFile(url: file.legacySessionURL).save(session)
    }
    let legacyBytes = try Data(contentsOf: file.legacySessionURL)
    let manager = try BrowserWorkspaceStore(file: file)
    var ids: WorkspaceProbeIdentity
    if phase == "initial" {
      try expect(
        !FileManager.default.fileExists(atPath: file.url.path),
        "reading a legacy session for managed restoration does not write a workspace")
      let first = manager.workspace.windows[0]
      let secondID = try manager.newWindow(from: first.id)
      let second = manager.stores[secondID]!
      second.perform(.open(fixture.appending(path: "workspace-second-live")))
      ids = WorkspaceProbeIdentity(
        first: first.id, second: secondID, alpha: first.session.spaces[0].id,
        beta: first.session.spaces[1].id, firstPin: first.session.spaces[0].tabs[0].id,
        secondPin: second.session.spaces[0].tabs[0].id,
        firstOrdinary: first.session.spaces[0].tabs[1].id,
        betaTab: first.session.spaces[1].tabs[0].id,
        closed: second.session.selectedSpace.selectedTabID!)
    } else {
      ids = try JSONDecoder().decode(
        WorkspaceProbeIdentity.self, from: Data(contentsOf: identityFile))
      try expect(
        Set(manager.workspace.windows.map(\.id)) == Set([ids.first, ids.second]),
        "both managed window identities restore from one saved manifest")
      try expect(
        manager.stores[ids.first]?.session.selectedSpaceID == ids.beta
          && manager.stores[ids.second]?.session.selectedSpace.selectedTabID == ids.secondPin,
        "each managed window restores its own Space and selected tab")
      try expect(
        manager.stores[ids.second]!.session.closedTabs.contains { $0.id == ids.closed },
        "window-local closed-tab recovery survives managed workspace restart")
    }
    try expect(
      manager.persistSnapshot(),
      "the full managed snapshot is saved before native window restoration")
    for window in manager.workspace.windows {
      try runtime.createWindowID(window.id.uuidString)
      let model = manager.stores[window.id]!
      let engine = try BrowserEngine(
        events: primary.events, windowID: window.id.uuidString, store: model,
        presentsNativePanels: false, lazyPinnedTabs: true)
      guard let content = runtime.hostView(forWindowID: window.id.uuidString) else {
        throw WorkspaceProbeFailure("Managed native host missing.")
      }
      let host = NSHostingView(rootView: BrowserWindow(store: model))
      host.frame = content.bounds
      host.autoresizingMask = [.width, .height]
      content.addSubview(host)
      hosts.append(host)
      clients[window.id] = engine
      engine.reconcile()
    }
    let first = manager.stores[ids.first]!
    let second = manager.stores[ids.second]!
    let selected = first.session.selectedSpace.selectedTabID!
    _ = try await document(selected)
    let background = selected == ids.firstOrdinary ? ids.betaTab : ids.firstOrdinary
    try expect(
      runtime.nativeTabID(forID: background.uuidString) == -1,
      "saved background ordinary tabs stay deferred until selection")
    first.perform(.tab(space: ids.alpha, tab: ids.firstOrdinary))
    _ = try await document(ids.firstOrdinary)
    first.perform(.tab(space: ids.beta, tab: ids.betaTab))
    let betaDocument = try await document(ids.betaTab)
    try expect(
      betaDocument["cookie"] as? String == "account=beta",
      "restored managed beta page uses its dedicated account")
    try expect(
      runtime.nativeTabID(forID: ids.firstPin.uuidString) == -1,
      "an unselected managed pin remains a row without starting a native page")
    if phase == "initial" {
      _ = try await document(ids.closed)
      try expect(
        runtime.nativeTabID(forID: ids.secondPin.uuidString) == -1,
        "new-window shared pin does not duplicate the first window's live page")
    } else {
      try expect(
        runtime.nativeTabID(forID: ids.closed.uuidString) == -1,
        "archived second-window page is not reopened during native restoration")
    }
    first.perform(.tab(space: ids.alpha, tab: ids.firstPin))
    var firstDocument = try await document(ids.firstPin)
    let firstNative = runtime.nativeTabID(forID: ids.firstPin.uuidString)
    if phase == "initial" {
      let address = fixture.appending(path: "workspace-pin-current").absoluteString
      let literal = String(data: try JSONEncoder().encode(address), encoding: .utf8)!
      navigate(ids.firstPin, literal: literal)
      firstDocument = try await document(ids.firstPin, address: address)
      try await wait("managed current pin navigation") {
        first.session.spaces.flatMap(\.tabs).first { $0.id == ids.firstPin }?.url.absoluteString
          == address
      }
    } else {
      try expect(
        firstDocument["url"] as? String
          == fixture.appending(path: "workspace-pin-current").absoluteString,
        "lazy first-window pin restores that window's current navigation address")
      try expect(
        firstDocument["instance"] as? String != ids.firstDocument,
        "restored pin has a fresh document rather than a serialized renderer")
    }
    try expect(
      firstDocument["cookie"] as? String == "account=alpha",
      "managed alpha pin retains its owning account")
    try expect(
      manager.workspace.catalog.spaces[0].tabs[0].url
        == fixture.appending(path: "workspace-pin-original")
        && second.session.spaces[0].tabs[0].url
          == fixture.appending(path: "workspace-pin-original"),
      "first-window navigation cannot change the shared original pin or another window's page")
    second.perform(.tab(space: ids.alpha, tab: ids.secondPin))
    let secondDocument = try await document(ids.secondPin)
    try expect(
      ids.firstPin != ids.secondPin
        && firstNative != runtime.nativeTabID(forID: ids.secondPin.uuidString)
        && firstDocument["instance"] as? String != secondDocument["instance"] as? String,
      "shared pin definitions materialize as distinct window-owned native documents")
    try expect(
      secondDocument["cookie"] as? String == "account=alpha",
      "separate pin instances explicitly share the profile account")
    try expect(
      runtime.windowID(forTabID: ids.firstPin.uuidString) == ids.first.uuidString
        && runtime.windowID(forTabID: ids.secondPin.uuidString) == ids.second.uuidString,
      "managed model identities bind to their restored native windows without implicit moves")
    if phase == "initial" {
      second.closeTab(ids.closed)
      try await wait("managed ordinary page closure") {
        second.session.closedTabs.contains { $0.id == ids.closed }
      }
    }
    try expect(
      !first.session.closedTabs.contains { $0.id == ids.closed },
      "managed writer never copies another window's recovery entries")
    try expect(
      first.updateSpace(ids.alpha, name: "Shared company tools", tint: .forest),
      "shared Space metadata can update through a managed application store")
    try expect(
      second.session.spaces[0].name == "Shared company tools",
      "shared Space metadata reaches the other real application client")
    let firstAfterCatalog = try await document(ids.firstPin) as NSDictionary
    let secondAfterCatalog = try await document(ids.secondPin) as NSDictionary
    try expect(
      firstAfterCatalog == firstDocument as NSDictionary
        && runtime.nativeTabID(forID: ids.firstPin.uuidString) == firstNative
        && secondAfterCatalog == secondDocument as NSDictionary,
      "catalog propagation preserves both existing window-owned native documents")
    first.toggleFolder(first.session.spaces[0].folders[0].id, in: ids.alpha)
    try expect(
      first.session.spaces[0].folders[0].isCollapsed
        && !second.session.spaces[0].folders[0].isCollapsed,
      "folder collapse remains window-local while its shared definition is unchanged")
    first.perform(.space(ids.beta))
    try manager.focusWindow(ids.second)
    try await captureWindows()
    try manager.flushSaves()
    try expect(
      try file.load() == manager.workspace && manager.workspace.focusedWindowID == ids.second,
      "one atomic manifest retains both models and focused window after native callbacks")
    try expect(
      try Data(contentsOf: file.legacySessionURL) == legacyBytes,
      "managed native navigation never rewrites the legacy source session")
    if phase == "initial" {
      ids.firstDocument = firstDocument["instance"] as? String
      ids.secondDocument = secondDocument["instance"] as? String
      try JSONEncoder().encode(ids).write(to: identityFile, options: .atomic)
    }
    for id in [ids.first, ids.second] {
      try expect(
        runtime.closeWindowID(id.uuidString), "managed fixture native window closes normally")
    }
    try await wait("managed native client shutdown") { self.clients.values.allSatisfy(\.isClosed) }
    try manager.flushSaves()
    try expect(
      manager.workspace.windows.count == 2 && (try file.load()) == manager.workspace,
      "retaining managed records for the next launch does not mistake native shutdown for tab closure"
    )
    try expect(
      !runtime.isQuitting && !primary.isClosed && store.session == mainSession,
      "managed window restoration experiment leaves the primary application model running")
    for base in bases {
      try expect(
        try await document(base.selectedTabID!) as NSDictionary == originals[base.selectedTabID!],
        "managed workspace lifecycle preserves unrelated live account document \(base.name)")
    }
  }

  private func navigate(_ tab: UUID, literal: String) {
    runtime.evaluate(
      inTabID: tab.uuidString, script: "(()=>{location.href=\(literal);return {};})()"
    ) { _ in }
  }

  private func captureWindows() async throws {
    for (index, host) in hosts.enumerated() {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw WorkspaceProbeFailure("Managed native capture failed.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw WorkspaceProbeFailure("Managed native PNG failed.")
      }
      try png.write(
        to: root.appending(path: "\(phase)-workspace-window-\(index + 1).png"), options: .atomic)
    }
  }

  private func document(_ tab: UUID, address: String? = nil) async throws -> [String: Any] {
    for _ in 0..<100 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tab.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,url:location.href,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account')})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1", value["instance"] as? String != nil,
        address == nil || value["url"] as? String == address
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WorkspaceProbeFailure("Managed fixture document not ready: \(tab).")
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WorkspaceProbeFailure("Timed out: \(label).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw WorkspaceProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Managed workspace format/writer and two hidden native clients restored across runner launches. Native records are intentionally retained for restart. Production host/Cmd-N, focused menus, native quit/close policy, window geometry, process-writer exclusion and physical input/focus are not verified here.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-workspace.json"), options: .atomic)
  }
}

private struct WorkspaceProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
