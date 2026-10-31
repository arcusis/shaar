// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import SwiftUI

@testable import ArcusisBrowser

/// Exercises two real application clients with one runtime, without showing either window.
@MainActor
final class WindowClientProbe {
  let primary: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var runtime: ARCChromiumRuntime { primary.runtime }
  private var checks: [String] = []
  private var secondary: BrowserEngine?
  private var secondStore: BrowserStore?
  private var hosting: NSHostingView<BrowserWindow>?
  private var popupHosts: [NSWindow] = []

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
    let base = store.session.spaces[0]
    store.perform(.space(base.id))
    store.dismissPageFind()
    let original = store.session
    let primaryIDs = Set(primary.pages.keys)
    let profile = base.profileID
    let tab = BrowserTab(url: fixture.appending(path: "window-client-\(phase)"))
    let space = BrowserSpace(
      profileID: profile, name: "Second window", symbol: "square", tint: .ocean, tabs: [tab])
    let session = try BrowserSession(
      profiles: store.session.profiles.filter { $0.id == profile }, spaces: [space],
      selectedSpaceID: space.id)
    let owner = UUID().uuidString
    try runtime.createWindowID(owner)
    let secondStore = BrowserStore(session: session)
    let secondary = try BrowserEngine(
      events: primary.events, windowID: owner, store: secondStore, presentsNativePanels: false)
    self.secondary = secondary
    self.secondStore = secondStore
    guard let content = runtime.hostView(forWindowID: owner) else {
      throw WindowClientFailure("Secondary native host is missing.")
    }
    let hosting = NSHostingView(rootView: BrowserWindow(store: secondStore))
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    self.hosting = hosting
    secondary.reconcile()
    try await wait("second client's page state") {
      secondary.pages[tab.id]?.loading == false
    }
    let initial = try await document(tab.id)
    try expect(
      initial["cookie"] as? String == "account=alpha" && initial["local"] as? String == "alpha",
      "second application client reuses the explicitly shared profile account")
    try expect(
      runtime.windowID(forTabID: tab.id.uuidString) == owner && secondary.events === primary.events,
      "two application clients share one dispatcher with distinct native window ownership")
    try expect(
      primary.pages[tab.id] == nil && Set(secondary.pages.keys).isDisjoint(with: primaryIDs),
      "secondary page callbacks never enter the primary client's cache")
    try expect(store.session == original, "secondary navigation leaves the primary model unchanged")
    var duplicate = false
    do {
      _ = try BrowserEngine(events: primary.events, windowID: owner, store: BrowserStore())
    } catch { duplicate = true }
    try expect(duplicate, "a duplicate application client cannot replace live window callbacks")

    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    secondStore.showPageFind()
    secondStore.updatePageFindQuery("MissingWindowClientNeedle")
    try await wait("independent application Find results") {
      self.store.pageFind?.matchCount == 3 && self.store.pageFind?.searching == false
        && secondStore.pageFind?.matchCount == 0 && secondStore.pageFind?.searching == false
    }
    try expect(true, "simultaneous Find callbacks update only their owning application stores")
    secondStore.dismissPageFind()
    try expect(store.pageFind?.matchCount == 3, "secondary Find dismissal preserves primary Find")
    store.dismissPageFind()

    try await wait("shared profile library snapshots") {
      secondStore.library.bookmarks[profile] != nil && self.store.library.bookmarks[profile] != nil
    }
    let address = fixture.appending(path: "window-client-bookmark-\(phase)").absoluteString
    let editor = BookmarkEditorRoute(
      profileID: profile,
      mode: .newBookmark(parent: nil, title: "Window client fixture", address: address))
    secondStore.showBookmarkEditor(editor)
    try expect(
      secondStore.saveBookmark(
        editor, title: "Window client fixture", address: address, parentID: nil),
      "secondary application submits a native bookmark mutation")
    try await wait("shared bookmark event fan-out") {
      self.store.library.bookmarks[profile]?.items.contains { $0.address == address } == true
        && secondStore.library.bookmarks[profile]?.items.contains { $0.address == address } == true
    }
    try expect(true, "native bookmark changes refresh both clients using the same profile")
    try await wait("secondary bookmark editor acknowledgement") { secondStore.sheet == nil }
    try expect(
      secondStore.deleteBookmark(editor.id, profileID: profile),
      "secondary application submits native bookmark removal")
    try await wait("shared bookmark removal fan-out") {
      self.store.library.bookmarks[profile]?.items.contains { $0.address == address } == false
        && secondStore.library.bookmarks[profile]?.items.contains { $0.address == address } == false
    }
    try expect(true, "native bookmark removal refreshes both independent library caches")
    try expect(
      secondStore.library.bookmarks.keys.allSatisfy { $0 == profile }
        && secondStore.library.history.keys.allSatisfy { $0 == profile },
      "a client receives no library state for profiles absent from its session")

    try await wait("shared profile history event") {
      self.store.library.history[profile]?.contains { $0.address == tab.url.absoluteString } == true
        && secondStore.library.history[profile]?.contains { $0.address == tab.url.absoluteString }
          == true
    }
    try expect(true, "secondary navigation refreshes shared native history in both windows")

    let name = "window-client-\(phase).txt"
    _ = try await evaluate(
      tab.id,
      """
      (()=>{const a=document.createElement('a');a.id='window-client-download';
        a.href='/download/\(name)';a.textContent='Download';document.body.append(a);return true;})()
      """)
    let clicked = await withCheckedContinuation { continuation in
      runtime.clickProbeElement(inTabID: tab.id.uuidString, elementID: "window-client-download") {
        continuation.resume(returning: $0)
      }
    }
    try expect(clicked, "trusted input starts an authored download in the secondary window")
    try await wait("shared download event fan-out") {
      secondary.downloads.items(in: profile).contains {
        $0.filename == name && $0.state == .finished
      }
        && self.primary.downloads.items(in: profile).contains {
          $0.filename == name && $0.state == .finished
        }
    }
    let download = secondary.downloads.items(in: profile).first {
      $0.filename == name
    }!
    try expect(
      download.fileURL.flatMap { try? Data(contentsOf: $0) }?.starts(
        with: Data("account=alpha\n".utf8))
        == true,
      "both clients observe the same real profile-authenticated completed download")
    try expect(
      secondary.downloads.perform(
        .remove, id: download.id, profileID: profile, selectedProfileID: profile),
      "secondary client can remove its shared-profile download record")
    try await wait("shared download removal") {
      secondary.downloads.records[profile]?[download.id] == nil
        && self.primary.downloads.records[profile]?[download.id] == nil
    }
    try expect(
      download.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
      "download removal updates both clients without deleting the file")

    primary.refreshExtensions()
    guard
      let extensionID = primary.extensions.first(where: { $0.name == "Account isolation probe" })?
        .id
    else {
      throw WindowClientFailure("Authored extension fixture missing.")
    }
    primary.executeExtension(extensionID)
    secondary.executeExtension(extensionID)
    guard case .popup(let firstPopup) = primary.extensionPanel,
      case .popup(let secondPopup) = secondary.extensionPanel,
      let firstView = runtime.view(forExtensionPopupID: firstPopup.id),
      let secondView = runtime.view(forExtensionPopupID: secondPopup.id)
    else { throw WindowClientFailure("Application popup routing failed.") }
    for view in [firstView, secondView] {
      let host = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
        backing: .buffered, defer: false)
      host.contentView = view
      popupHosts.append(host)
    }
    try expect(
      firstPopup.id != secondPopup.id && firstPopup.tabID == base.selectedTabID
        && secondPopup.tabID == tab.id && firstView !== secondView,
      "extension popup callbacks reach two distinct owning application clients")
    secondary.extensionPanel = nil
    try expect(
      primary.extensionPanel?.id == ExtensionPanelRoute.popup(firstPopup).id
        && runtime.view(forExtensionPopupID: firstPopup.id) != nil
        && runtime.view(forExtensionPopupID: secondPopup.id) == nil,
      "secondary popup closure leaves the primary application popup intact")
    primary.extensionPanel = nil

    secondStore.perform(.open(fixture.appending(path: "window-client-close-\(phase)")))
    let temporary = secondStore.session.selectedSpace.selectedTabID!
    _ = try await document(temporary)
    secondStore.closeTab(temporary)
    try await wait("secondary application tab closure") {
      secondStore.session.closedTabs.contains { $0.id == temporary }
        && secondary.pages[temporary] == nil
    }
    try expect(
      !store.session.closedTabs.contains { $0.id == temporary } && store.session == original,
      "native tab-close delivery records recovery only in the owning application store")
    let closedSession = secondStore.session
    try expect(runtime.closeWindowID(owner), "secondary application window accepts normal closure")
    try await wait("secondary application window cleanup") { secondary.isClosed }
    try expect(
      !primary.isClosed && !runtime.isQuitting && secondStore.session == closedSession,
      "window-close delivery preserves saved tabs and leaves the primary client running")
    secondary.reconcile()
    try expect(
      runtime.nativeTabID(forID: tab.id.uuidString) == -1 && secondary.pages.isEmpty,
      "closed application client cannot recreate its native tabs during reconciliation")
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    try await wait("primary callbacks after secondary shutdown") {
      self.store.pageFind?.matchCount == 3 && self.store.pageFind?.searching == false
    }
    store.dismissPageFind()
    try expect(
      store.session == original && Set(primary.pages.keys) == primaryIDs,
      "primary callbacks and model survive the secondary application lifecycle")
  }

  private func evaluate(_ tab: UUID, _ expression: String) async throws -> Any {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: expression) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else {
      throw WindowClientFailure("Fixture evaluation failed.")
    }
    return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
  }

  private func document(_ tab: UUID) async throws -> [String: Any] {
    for _ in 0..<80 {
      if let value = try? await evaluate(
        tab,
        "({fixture:document.documentElement.dataset.arcusisFixture,cookie:document.cookie,local:localStorage.getItem('account')})"
      ) as? [String: Any], value["fixture"] as? String == "v1" {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WindowClientFailure("Secondary fixture document did not become ready.")
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WindowClientFailure("Timed out: \(label).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw WindowClientFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Two hidden application stores/clients with one event dispatcher and a shared normal profile. No Cmd-N, per-window session manifest/restoration, menus/focus, real accounts or physical input.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-window-clients.json"), options: .atomic)
  }
}

private struct WindowClientFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
