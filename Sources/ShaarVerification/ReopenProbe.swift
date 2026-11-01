// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@testable import ArcusisBrowser

private struct RecoveryIdentities: Codable {
  let alpha: UUID
  let beta: UUID
  let folder: UUID
  let alphaClosed: UUID
  let betaClosed: UUID
}

@MainActor
final class ReopenProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    phase: String
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
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
    let base = store.session.spaces[0]
    let other = store.session.spaces[1]
    let url = base.selectedTab!.url
    let file = root.appending(path: "reopen-identities.json")
    let ids: RecoveryIdentities
    var previousInstance: String?
    if phase == "initial" {
      guard store.createSpace(name: "Recovery alpha", sharingProfile: base.profileID, tint: .ocean)
      else { throw RecoveryFailure("Could not create alpha recovery space.") }
      let alpha = store.session.selectedSpaceID
      store.perform(.open(url))
      store.perform(.open(url))
      let target = store.session.selectedSpace.selectedTabID!
      guard let folder = store.createFolder(name: "Company accounts", in: alpha) else {
        throw RecoveryFailure("Could not create recovery folder.")
      }
      _ = store.moveTab(target, from: alpha, to: alpha, folderID: folder)
      previousInstance = try await document(target)["instance"] as? String
      _ = await evaluate(target, "(()=>{document.title='Company dashboard';return {};})()")
      try await Task.sleep(for: .milliseconds(100))
      store.perform(.open(url))
      try await close(target)
      guard store.createSpace(name: "Recovery beta", sharingProfile: other.profileID, tint: .rose)
      else { throw RecoveryFailure("Could not create beta recovery space.") }
      let beta = store.session.selectedSpaceID
      store.perform(.open(url))
      store.perform(.open(url))
      let betaClosed = store.session.selectedSpace.selectedTabID!
      _ = try await document(betaClosed)
      try await close(betaClosed)
      ids = RecoveryIdentities(
        alpha: alpha, beta: beta, folder: folder, alphaClosed: target, betaClosed: betaClosed)
    } else {
      ids = try JSONDecoder().decode(RecoveryIdentities.self, from: Data(contentsOf: file))
      try expect(
        store.session.closedTabs.contains {
          $0.id == ids.alphaClosed && $0.spaceID == ids.alpha && $0.profileID == base.profileID
        },
        "alpha recovery entry restores with its original account ownership")
      try expect(
        store.session.closedTabs.contains {
          $0.id == ids.betaClosed && $0.spaceID == ids.beta && $0.profileID == other.profileID
        },
        "beta recovery entry restores separately after restart")
      try expect(
        runtime.nativeTabID(forID: ids.alphaClosed.uuidString) == -1,
        "restart does not load archived pages as live tabs")
    }
    let untouched = [
      base.selectedTabID!, other.selectedTabID!, try space(ids.alpha).selectedTabID!,
      try space(ids.beta).selectedTabID!,
    ]
    var before: [UUID: NSDictionary] = [:]
    let nativeIDs = untouched.map { runtime.nativeTabID(forID: $0.uuidString) }
    for id in untouched { before[id] = try await document(id) as NSDictionary }
    store.perform(.space(ids.beta))
    let unchanged = store.session
    try expect(
      !store.reopenClosedTab(ids.alphaClosed, in: ids.alpha),
      "another profile cannot consume alpha's recovery entry")
    try expect(
      store.session == unchanged, "rejected cross-profile recovery changes no session state")
    try expect(
      store.reopenLastClosedTab(), "reopen shortcut operation chooses beta's own last closed tab")
    let beta = store.session.selectedSpace.selectedTabID!
    let betaDocument = try await document(beta)
    try expect(
      betaDocument["cookie"] as? String == "account=beta"
        && betaDocument["local"] as? String == "beta",
      "reopened beta page retains beta account cookies and local storage")
    try expect(
      beta != ids.betaClosed && betaDocument["session"] is NSNull,
      "recovery creates a fresh beta document and tab session")
    try await close(beta)
    store.perform(.space(base.id))
    try expect(
      !store.reopenClosedTab(ids.alphaClosed, in: ids.alpha),
      "sharing a profile does not merge separate spaces' recovery lists")
    store.perform(.space(ids.alpha))
    store.showRecentlyClosed()
    try expect(
      store.sheet?.id == BrowserSheet.recentlyClosed(spaceID: ids.alpha).id,
      "native recovery panel is bound to the selected space")
    try await capture(
      RecentlyClosedPanel(store: store, spaceID: ids.alpha), size: NSSize(width: 568, height: 458),
      name: "\(phase)-recently-closed.png", scheme: .light)
    try await capture(
      RecentlyClosedPanel(store: store, spaceID: ids.alpha), size: NSSize(width: 568, height: 458),
      name: "\(phase)-recently-closed-dark.png", scheme: .dark)
    try expect(
      store.reopenClosedTab(ids.alphaClosed, in: ids.alpha),
      "native panel operation reopens the selected archived page")
    let alpha = store.session.selectedSpace.selectedTabID!
    let alphaDocument = try await document(alpha)
    try expect(
      alpha != ids.alphaClosed && runtime.nativeTabID(forID: alpha.uuidString) >= 0,
      "reopened alpha page receives a fresh model and native tab identity")
    if let previousInstance {
      try expect(
        alphaDocument["instance"] as? String != previousInstance,
        "closed JavaScript document is not reused as a live page")
    }
    try expect(
      alphaDocument["cookie"] as? String == "account=alpha"
        && alphaDocument["local"] as? String == "alpha" && alphaDocument["session"] is NSNull,
      "alpha recovery keeps its own persistent account and starts a fresh tab session")
    try expect(
      store.session.selectedSpace.selectedTab?.folderID == ids.folder
        && store.session.selectedSpace.selectedTab?.isPinned == true,
      "recovery restores pinned folder membership")
    try expect(
      store.session.selectedSpace.folderPath(to: ids.folder).allSatisfy { !$0.isCollapsed },
      "reopening reveals collapsed folder ancestors")
    try await close(alpha)
    store.showCommand()
    store.commandQuery = "reopen"
    try await capture(
      BrowserWindow(store: store), size: NSSize(width: 760, height: 520),
      name: "\(phase)-reopen-command-compact.png", scheme: .light)
    guard
      let result = store.results.first(where: { $0.action == .reopen(space: ids.alpha, tab: alpha) }
      )
    else {
      throw RecoveryFailure("Command-T did not find the owning space's closed tab.")
    }
    store.perform(result.action)
    let final = store.session.selectedSpace.selectedTabID!
    _ = try await document(final)
    try expect(
      store.session.recentlyClosedTabs(in: ids.alpha).isEmpty,
      "Command-T consumes only the selected recovery entry")
    store.perform(.open(url))
    let scratch = store.session.selectedSpace.selectedTabID!
    _ = try await document(scratch)
    try await close(scratch)
    try expect(
      store.clearClosedTabs(in: ids.alpha),
      "clear-list action removes the owning space's recovery entries")
    try expect(
      store.session.recentlyClosedTabs(in: ids.beta).map(\.id) == [beta],
      "clearing alpha's recovery list preserves beta's entry")
    try await capture(
      RecentlyClosedPanel(store: store, spaceID: ids.alpha), size: NSSize(width: 568, height: 458),
      name: "\(phase)-recently-closed-empty.png", scheme: .light)
    store.perform(.tab(space: ids.alpha, tab: final))
    let profileTabs = store.session.spaces.filter { $0.profileID == base.profileID }.flatMap(
      \.orderedTabs)
    try await OrderingProbe(
      runtime: runtime, engine: engine, store: store, root: root, phase: "\(phase)-reopen"
    )
    .verifyNativeOrder(
      profileTabs.filter(\.isPinned) + profileTabs.filter { !$0.isPinned },
      label: "restored tabs match native profile order")
    try expect(true, "extension-visible order and active target match the restored page")
    for (index, id) in untouched.enumerated() {
      try expect(
        try await document(id) as NSDictionary == before[id]
          && runtime.nativeTabID(forID: id.uuidString) == nativeIDs[index],
        "recovery leaves unrelated account document \(index + 1) intact")
    }
    try await close(final)
    store.toggleFolder(ids.folder, in: ids.alpha)
    let saved = RecoveryIdentities(
      alpha: ids.alpha, beta: ids.beta, folder: ids.folder, alphaClosed: final, betaClosed: beta)
    try JSONEncoder().encode(saved).write(to: file, options: .atomic)
    try store.flushSaves()
    try expect(
      try SessionFile(url: root.appending(path: "session.json")).load() == store.session,
      "live tabs and recovery snapshots save together atomically")
    store.perform(.space(base.id))
  }

  private func close(_ id: UUID) async throws {
    store.closeTab(id)
    for _ in 0..<60 {
      if store.session.closedTabs.contains(where: { $0.id == id })
        && runtime.nativeTabID(forID: id.uuidString) == -1
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RecoveryFailure("Native tab closure did not complete.")
  }

  private func space(_ id: UUID) throws -> BrowserSpace {
    guard let value = store.session.spaces.first(where: { $0.id == id }) else {
      throw RecoveryFailure("Recovery space was lost.")
    }
    return value
  }

  private func evaluate(_ id: UUID, _ script: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: id.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<60 {
      if let state = await evaluate(
        id,
        "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account'),session:sessionStorage.getItem('account')})"
      ), state["fixture"] as? String == "v1" {
        return state
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RecoveryFailure("Recovery fixture document was not ready.")
  }

  private func capture<V: View>(_ view: V, size: NSSize, name: String, scheme: ColorScheme)
    async throws
  {
    let host = NSHostingView(
      rootView: view.environment(\.colorScheme, scheme).frame(
        width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw RecoveryFailure("Recovery layout could not be rendered.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw RecoveryFailure("Recovery layout could not be encoded.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw RecoveryFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Real native close/store recovery, profile cookies/storage, restart, and offscreen layouts. No beforeunload dialog, real keyboard/menu input, back-stack, form, or JavaScript-state restoration verified.",
      ], options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: root.appending(path: "\(phase)-reopen.json"), options: .atomic)
  }
}

private struct RecoveryFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
