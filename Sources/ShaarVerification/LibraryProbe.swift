// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import SwiftUI

@testable import ArcusisBrowser

private struct LibraryIdentities: Codable {
  let alpha: UUID
  let beta: UUID
  let shared: UUID
  let folder: UUID
  let bookmarkA: UUID
  let bookmarkB: UUID
}

@MainActor
final class LibraryProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?
  private var popupWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    fixture: URL, phase: String
  ) {
    self.runtime = runtime
    self.engine = engine
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
      engine.extensionPanel = nil
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    let bases = Array(store.session.spaces.prefix(3))
    let a = bases[0].profileID
    let b = bases[1].profileID
    var documents: [UUID: NSDictionary] = [:]
    let nativeIDs = bases.map { runtime.nativeTabID(forID: $0.selectedTabID!.uuidString) }
    for base in bases {
      documents[base.selectedTabID!] = try await document(base.selectedTabID!) as NSDictionary
    }
    let persistedA = url("library-alpha-persisted")
    let persistedB = url("library-beta-persisted")
    let savedA = url("library-alpha-saved")
    let savedB = url("library-beta-saved")
    let external = url("library-alpha-extension")
    let file = root.appending(path: "library-identities.json")
    let ids: LibraryIdentities
    if phase == "initial" {
      let alpha = try createSpace("Library alpha", profile: a)
      try await visitAndClose(persistedA)
      let folder = try await create(
        .newFolder(parent: nil), profile: a, title: "Company", address: "")
      let bookmarkA = try await create(
        .newBookmark(parent: folder, title: "Alpha console", address: savedA.absoluteString),
        profile: a, title: "Alpha console", address: savedA.absoluteString)
      let beta = try createSpace("Library beta", profile: b)
      try await visitAndClose(persistedB)
      let bookmarkB = try await create(
        .newBookmark(parent: nil, title: "Beta console", address: savedB.absoluteString),
        profile: b, title: "Beta console", address: savedB.absoluteString)
      let shared = try createSpace("Library shared", profile: a)
      ids = LibraryIdentities(
        alpha: alpha, beta: beta, shared: shared, folder: folder, bookmarkA: bookmarkA,
        bookmarkB: bookmarkB)
      try JSONEncoder().encode(ids).write(to: file, options: .atomic)
    } else {
      ids = try JSONDecoder().decode(LibraryIdentities.self, from: Data(contentsOf: file))
      try await wait("native bookmark restart recovery") {
        self.item(ids.bookmarkA, in: a) != nil && self.item(ids.bookmarkB, in: b) != nil
      }
      try expect(
        item(ids.bookmarkA, in: a)?.parentID == ids.folder,
        "bookmark hierarchy persists in the native profile after restart")
      try expect(
        item(ids.bookmarkB, in: a) == nil && item(ids.bookmarkA, in: b) == nil,
        "bookmark IDs remain isolated across profile restart")
      try await wait("native history restart recovery") {
        self.hasHistory(persistedA, in: a) && self.hasHistory(persistedB, in: b)
      }
      try expect(true, "closed-page history restores from the engine without reopening those pages")
      try expect(
        store.library.bookmarks[a]?.items.contains { $0.address == external.absoluteString }
          == true,
        "extension-created native bookmark survives restart")
    }
    try await wait("initial native library snapshots") {
      self.store.library.bookmarks[a] != nil && self.store.library.bookmarks[b] != nil
    }
    try expect(
      store.library.watchNotices.isEmpty, "native bookmark/history watchers register successfully")
    let limited = try await runtime.history(forProfileID: a.uuidString, limit: 1)
    try expect(limited.count == 1, "native history query honors the requested result bound")
    var unknownBookmarks = false
    var unknownHistory = false
    do { _ = try await runtime.bookmarks(forProfileID: UUID().uuidString) } catch {
      unknownBookmarks = true
    }
    do { _ = try await runtime.history(forProfileID: UUID().uuidString, limit: 500) } catch {
      unknownHistory = true
    }
    try expect(
      unknownBookmarks == true && unknownHistory == true,
      "native library calls reject unknown profiles without a fallback")
    store.perform(.space(ids.alpha))
    let edit = BookmarkEditorRoute(profileID: a, mode: .edit(ids.bookmarkA))
    store.showBookmarkEditor(edit)
    try expect(
      store.saveBookmark(
        edit, title: "Company dashboard Alpha", address: savedA.absoluteString, parentID: ids.folder
      ),
      "native bookmark editor submits metadata in its owning profile")
    try await wait("bookmark title acknowledgement") {
      self.item(ids.bookmarkA, in: a)?.title == "Company dashboard Alpha" && self.store.sheet == nil
    }
    let tree = store.library.bookmarks[a]!
    try expect(
      store.moveBookmark(ids.bookmarkA, profileID: a, to: tree.barID),
      "bookmark can move to another native root")
    try await wait("bookmark root move") { self.item(ids.bookmarkA, in: a)?.parentID == tree.barID }
    try expect(
      store.moveBookmark(ids.bookmarkA, profileID: a, to: ids.folder),
      "bookmark can move back into its native folder")
    try await wait("bookmark folder move") {
      self.item(ids.bookmarkA, in: a)?.parentID == ids.folder
    }
    try expect(
      !store.moveBookmark(ids.folder, profileID: a, to: ids.folder)
        && !store.deleteBookmark(tree.barID, profileID: a),
      "native library controls reject folder cycles and permanent-root deletion")
    let stale = CommandAction.bookmark(profile: a, id: ids.bookmarkA)
    store.perform(.space(ids.beta))
    let unchanged = store.session
    store.perform(stale)
    try expect(
      store.session == unchanged && !store.deleteBookmark(ids.bookmarkA, profileID: a),
      "stale library actions cannot open or delete another account's bookmark")
    var foreignRejected = false
    do {
      try await runtime.applyBookmarkOperation(
        ["op": "remove", "id": ids.bookmarkA.uuidString.lowercased()], profileID: b.uuidString)
    } catch { foreignRejected = true }
    try expect(foreignRejected == true, "engine profile boundary rejects a foreign bookmark ID")
    store.library.refresh(a, section: .bookmarks)
    store.library.refresh(b, section: .bookmarks)
    try await wait("post-rejection native snapshots") {
      !self.store.library.loading.contains(LibraryKey(profileID: a, section: .bookmarks))
        && !self.store.library.loading.contains(LibraryKey(profileID: b, section: .bookmarks))
    }
    try expect(
      item(ids.bookmarkA, in: a) != nil && item(ids.bookmarkB, in: b) != nil,
      "failed cross-profile operations preserve both native bookmark stores")
    let foreign = try await extensionCommand(
      space: ids.beta, message: ["action": "library-read", "url": savedA.absoluteString])
    try expect(
      (foreign["bookmarks"] as? [Any])?.isEmpty == true && foreign["account"] as? String == "beta",
      "beta extension cannot read alpha's native bookmark")
    let own = try await extensionCommand(
      space: ids.alpha, message: ["action": "library-read", "url": savedA.absoluteString])
    try expect(
      (own["bookmarks"] as? [[String: Any]])?.first?["title"] as? String
        == "Company dashboard Alpha" && own["account"] as? String == "alpha",
      "native bookmark edits are visible through chrome.bookmarks in the owning profile")
    let history = try await extensionCommand(
      space: ids.alpha, message: ["action": "library-read", "url": persistedA.absoluteString])
    try expect(
      (history["history"] as? [[String: Any]])?.contains {
        $0["url"] as? String == persistedA.absoluteString
      } == true,
      "chrome.history agrees with the native history service")
    _ = try await extensionCommand(
      space: ids.alpha,
      message: [
        "action": "library-write", "url": external.absoluteString,
        "title": "Extension bookmark \(phase)",
      ])
    try await wait("extension bookmark event delivery") {
      self.store.library.bookmarks[a]?.items.contains {
        $0.address == external.absoluteString && $0.title == "Extension bookmark \(self.phase)"
      } == true
    }
    try expect(true, "extension bookmark changes refresh native UI data without a manual reload")
    try expect(
      store.library.bookmarks[b]?.items.contains { $0.address == external.absoluteString } == false,
      "alpha bookmark events do not contaminate beta's cached library")
    store.perform(.space(ids.alpha))
    let transient = url("library-alpha-delete-\(phase)")
    try await visitAndClose(transient)
    try await wait("history visit event delivery") { self.hasHistory(transient, in: a) }
    try expect(
      !hasHistory(transient, in: b) && hasHistory(persistedB, in: b),
      "real page visits appear only in their owning native history")
    store.showLibrary(.history)
    try await capture(
      LibraryPanel(store: store, profileID: a, section: .history), name: "\(phase)-history.png",
      size: NSSize(width: 648, height: 528), scheme: .light)
    try expect(
      store.deleteHistoryEntry(transient.absoluteString, profileID: a),
      "native history removal submits in its owning profile")
    try await wait("history deletion acknowledgement") {
      !self.hasHistory(transient, in: a)
        && !self.store.library.loading.contains(LibraryKey(profileID: a, section: .history))
    }
    try expect(
      hasHistory(persistedA, in: a) && hasHistory(persistedB, in: b),
      "history removal preserves other addresses and another profile's history")
    store.sheet = nil
    store.sheetDidDismiss()
    store.showLibrary(.bookmarks)
    try await capture(
      LibraryPanel(store: store, profileID: a, section: .bookmarks), name: "\(phase)-bookmarks.png",
      size: NSSize(width: 648, height: 528), scheme: .light)
    try await capture(
      LibraryPanel(store: store, profileID: a, section: .bookmarks),
      name: "\(phase)-bookmarks-dark.png", size: NSSize(width: 648, height: 528), scheme: .dark)
    store.showBookmarkEditor(BookmarkEditorRoute(profileID: a, mode: .edit(ids.bookmarkA)))
    if case .bookmarkEditor(let route) = store.sheet {
      try await capture(
        BookmarkEditor(store: store, route: route), name: "\(phase)-bookmark-editor.png",
        size: NSSize(width: 516, height: 360), scheme: .light)
    } else {
      throw LibraryProbeFailure("Bookmark editor did not retain its native route.")
    }
    store.sheet = nil
    store.sheetDidDismiss()
    store.showCommand()
    store.commandQuery = "library-alpha-saved"
    try expect(
      store.results.contains { $0.action == stale },
      "Command-T finds the selected profile's native bookmark")
    try await capture(
      BrowserWindow(store: store), name: "\(phase)-library-command-compact.png",
      size: NSSize(width: 760, height: 520), scheme: .light)
    store.dismissCommand()
    store.perform(.space(ids.shared))
    let count = store.session.selectedSpace.tabs.count
    try expect(
      store.openBookmark(ids.bookmarkA, profileID: a),
      "explicitly shared space opens the same native bookmark")
    let opened = store.session.selectedSpace.selectedTabID!
    let page = try await document(opened)
    try expect(
      store.session.selectedSpaceID == ids.shared
        && store.session.selectedSpace.tabs.count == count + 1
        && page["cookie"] as? String == "account=alpha",
      "library navigation creates a page in the current shared space with its alpha account")
    let temporary = try await create(
      .newFolder(parent: nil), profile: a, title: "Temporary bookmarks", address: "")
    let child = try await create(
      .newBookmark(
        parent: temporary, title: "Disposable",
        address: url("library-alpha-disposable").absoluteString), profile: a, title: "Disposable",
      address: url("library-alpha-disposable").absoluteString)
    try expect(
      store.deleteBookmark(temporary, profileID: a), "native folder removal is acknowledged")
    try await wait("native subtree removal") {
      self.item(temporary, in: a) == nil && self.item(child, in: a) == nil
    }
    try expect(
      item(ids.bookmarkA, in: a) != nil && item(ids.bookmarkB, in: b) != nil,
      "deleting a bookmark subtree preserves unrelated bookmarks in both profiles")
    for (index, base) in bases.enumerated() {
      let id = base.selectedTabID!
      try expect(
        try await document(id) as NSDictionary == documents[id]
          && runtime.nativeTabID(forID: id.uuidString) == nativeIDs[index],
        "library operations retain unrelated live account document \(index + 1)")
    }
    try store.flushSaves()
    try expect(
      try SessionFile(url: root.appending(path: "session.json")).load() == store.session,
      "library UI does not corrupt the persisted browser session")
    store.perform(.space(bases[0].id))
  }

  private func createSpace(_ name: String, profile: UUID) throws -> UUID {
    guard store.createSpace(name: name, sharingProfile: profile, tint: .forest) else {
      throw LibraryProbeFailure("Could not create library fixture space.")
    }
    let id = store.session.selectedSpaceID
    store.perform(.open(fixture))
    return id
  }

  private func create(_ mode: BookmarkEditorMode, profile: UUID, title: String, address: String)
    async throws -> UUID
  {
    let route = BookmarkEditorRoute(profileID: profile, mode: mode)
    store.showBookmarkEditor(route)
    guard store.saveBookmark(route, title: title, address: address, parentID: route.parentID) else {
      throw LibraryProbeFailure("Bookmark save was rejected.")
    }
    try await wait("native bookmark save") {
      self.item(route.id, in: profile) != nil && self.store.sheet == nil
    }
    return route.id
  }

  private func visitAndClose(_ url: URL) async throws {
    store.perform(.open(url))
    let tab = store.session.selectedSpace.selectedTabID!
    _ = try await document(tab)
    store.closeTab(tab)
    try await wait("library fixture tab close") {
      self.runtime.nativeTabID(forID: tab.uuidString) == -1
        && self.store.session.closedTabs.contains { $0.id == tab }
    }
  }

  private func item(_ id: UUID, in profile: UUID) -> BrowserBookmark? {
    store.library.bookmarks[profile]?.items.first { $0.id == id }
  }
  private func hasHistory(_ url: URL, in profile: UUID) -> Bool {
    store.library.history[profile]?.contains { $0.address == url.absoluteString } == true
  }
  private func url(_ path: String) -> URL {
    var parts = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    parts.path = "/\(path)"
    parts.query = nil
    parts.fragment = nil
    return parts.url!
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<80 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    let profile = store.session.selectedSpace.profileID
    throw LibraryProbeFailure(
      "Timed out: \(label). \(store.library.notice(profile, section: .bookmarks) ?? store.library.notice(profile, section: .history) ?? "No service notice.")"
    )
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<60 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: id.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account'),session:sessionStorage.getItem('account')})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1"
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw LibraryProbeFailure("Library fixture page was not ready.")
  }

  private func extensionCommand(space: UUID, message: [String: String]) async throws -> [String:
    Any]
  {
    store.perform(.space(space))
    engine.extensionPanel = nil
    engine.refreshExtensions()
    guard let fixture = engine.extensions.first(where: { $0.name == "Account isolation probe" })
    else { throw LibraryProbeFailure("Library MV3 fixture missing.") }
    engine.executeExtension(fixture.id)
    guard case .popup(let popup) = engine.extensionPanel else {
      throw LibraryProbeFailure("Library MV3 popup missing.")
    }
    defer { engine.extensionPanel = nil }
    if let page = runtime.view(forExtensionPopupID: popup.id) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.contentView = page
      popupWindow = window
    }
    let encoded = String(
      data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
    for _ in 0..<60 {
      let ready = await popupValue(
        popup.id, expression: "({ready:typeof window.probeCommand==='function'})")
      if ready?["ready"] as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    _ = await popupValue(
      popup.id,
      expression:
        "(()=>{window.libraryReply=null;window.probeCommand(\(encoded)).then(v=>window.libraryReply=v).catch(e=>window.libraryReply={error:String(e)});return {};})()"
    )
    for _ in 0..<60 {
      if let reply = await popupValue(popup.id, expression: "window.libraryReply") {
        guard reply["error"] == nil else {
          throw LibraryProbeFailure("Library extension failed: \(reply["error"]!)")
        }
        return reply
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw LibraryProbeFailure("Library extension did not answer.")
  }

  private func popupValue(_ id: String, expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(id, script: expression) { continuation.resume(returning: $0) }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func capture<V: View>(_ view: V, name: String, size: NSSize, scheme: ColorScheme)
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
      throw LibraryProbeFailure("Library layout could not render.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw LibraryProbeFailure("Library layout could not encode.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw LibraryProbeFailure(message) }
    checks.append(message)
  }
  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Real engine-owned bookmark/history APIs, MV3 visibility/events, account boundaries, restart, and offscreen native layouts. Actual native shortcuts/menu/dialog/pointer input and private-session behavior are not verified.",
      ], options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: root.appending(path: "\(phase)-library.json"), options: .atomic)
  }
}

private struct LibraryProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
