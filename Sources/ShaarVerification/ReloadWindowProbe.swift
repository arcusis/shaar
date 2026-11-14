// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification

@testable import ArcusisBrowser

enum ReloadWindowProbeEvidence {
  static func isCrossSiteLoopbackNavigation(source: URL, destination: String?) -> Bool {
    guard let destination = destination.flatMap(URL.init(string:)) else { return false }
    return source.scheme == "http" && source.host == "127.0.0.1"
      && destination.scheme == "http" && destination.host == "localhost"
  }
}

/// Hidden, two-origin link and failed-page reload exercise for issue 1066.
@MainActor
final class ReloadWindowProbe {
  let runtime: ARCChromiumRuntime
  let events: BrowserRuntimeEvents
  let root: URL
  let fixture: URL
  let profile: BrowserProfile
  private var checks: [String] = []

  init(
    runtime: ARCChromiumRuntime, events: BrowserRuntimeEvents, root: URL, fixture: URL,
    profile: BrowserProfile
  ) {
    self.runtime = runtime
    self.events = events
    self.root = root
    self.fixture = fixture
    self.profile = profile
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
    let originA = fixture.deletingLastPathComponent().appending(path: "cross-site-a")
    let host = try makeHost(profile: profile, originA: originA, fileStem: "reload-window")
    defer { host.detach() }
    let ownerID = try require(host.contexts.keys.first, "Reload probe has no window")
    checks.append(
      try await exerciseLink(
        "plain", elementID: "plain", ownerID: ownerID, originA: originA, host: host))
    for _ in 2...5 {
      _ = try await exerciseLink(
        "plain", elementID: "plain", ownerID: ownerID, originA: originA, host: host)
    }
    checks.append("plain cross-site link reached the second site five times")

    let owner = try require(host.contexts[ownerID], "Source window closed before reload")
    owner.store.perform(.open(originA))
    let retained = try require(owner.store.session.selectedPage?.tab.id, "Missing retained tab")
    try await wait("retained page") { await document(retained, runtime: runtime) != nil }
    owner.store.togglePin(retained)
    runtime.closeTabID(retained.uuidString)
    try await wait("failed-page view") { owner.store.rendererFailures[retained] != nil }
    let failure = try require(owner.store.rendererFailures[retained], "Missing failed-page state")
    let accepted = owner.store.reloadFailedPage(failure.id)
    try expect(accepted, reloadRejection(owner, failure: failure, tab: retained))
    try await wait("reloaded document") {
      await document(retained, runtime: runtime)?["href"] as? String == originA.absoluteString
        && owner.store.rendererFailures[retained] == nil
    }
    checks.append("failed-page Reload recreates a destroyed pinned tab")

    owner.store.nativeRendererGone(
      retained, profileID: profile.id, status: "renderer_gone", exitCode: 0)
    let closedFailure = try require(owner.store.rendererFailures[retained], "Missing close case")
    try expect(runtime.closeWindowID(owner.nativeID), "Engine window closes before Reload")
    try await wait("retired engine window") { !runtime.isWindowOpenID(owner.nativeID) }
    _ = owner.store.reloadFailedPage(closedFailure.id)
    try await wait("replacement managed window") {
      host.contexts[ownerID]?.nativeID != owner.nativeID
    }
    let replacement = try require(host.contexts[ownerID], "No replacement window")
    try expect(
      replacement.store === owner.store && !replacement.window.isVisible,
      "closed engine window rehomes its retained tab into a hidden live window")
    try await wait("retained page in replacement window") {
      await document(retained, runtime: runtime)?["href"] as? String == originA.absoluteString
        && replacement.store.rendererFailures[retained] == nil
    }
    checks.append("Reload after engine-window closure rehomes the tab without quitting")
    checks.append(try await exerciseFreshProfileWindow(originA: originA))
    for (name, elementID) in [("target blank", "blank"), ("window.open", "popup")] {
      checks.append(
        try await exerciseLink(
          name, elementID: elementID, ownerID: ownerID, originA: originA, host: host))
    }
  }

  private func makeHost(
    profile: BrowserProfile, originA: URL, fileStem: String
  ) throws -> NativeBrowserHost {
    let first = BrowserTab(url: originA)
    let space = BrowserSpace(
      profileID: profile.id, name: "Links", symbol: "globe", tint: .ocean,
      tabs: [first], selectedTabID: first.id)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let file = WorkspaceFile(
      url: root.appending(path: "\(fileStem)-workspace.json"),
      legacySessionURL: root.appending(path: "\(fileStem)-session.json"))
    let workspace = try BrowserWorkspaceStore(file: file, initialSession: session)
    let host = NativeBrowserHost(
      events: events, workspace: workspace, presentation: .hiddenProbe,
      usesPrimaryWindow: false)
    try host.restore()
    return host
  }

  private func exerciseFreshProfileWindow(originA: URL) async throws -> String {
    let profile = BrowserProfile(name: "Fresh reload probe")
    let host = try makeHost(profile: profile, originA: originA, fileStem: "reload-window-fresh")
    defer { host.detach() }
    try await wait("fresh profile first tab") {
      guard let context = host.contexts.values.first,
        let tab = context.store.session.selectedPage?.tab.id
      else { return false }
      return await document(tab, runtime: runtime)?["href"] as? String == originA.absoluteString
        && runtime.windowID(forTabID: tab.uuidString) == context.nativeID
    }
    try expect(
      host.contexts.values.allSatisfy { $0.store.rendererFailures.isEmpty && !$0.window.isVisible }
        && NSApp.windows.allSatisfy { !$0.isVisible },
      "fresh profile opens its first tab in an owned hidden regular window")
    return "fresh profile materializes its first tab in a second hidden regular window"
  }

  private func report(error: Error?) throws {
    let proof: [String: Any] = [
      "schema": 1, "passed": error == nil, "checks": checks,
      "error": error?.localizedDescription as Any? ?? NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys])
      .write(to: root.appending(path: "reload-window-evidence.json"), options: .atomic)
  }

  private func exerciseLink(
    _ name: String, elementID: String, ownerID: UUID, originA: URL, host: NativeBrowserHost
  ) async throws -> String {
    let owner = try require(host.contexts[ownerID], "Source window closed during \(name)")
    owner.store.perform(.open(originA))
    let source = try require(owner.store.session.selectedPage?.tab.id, "Missing \(name) tab")
    try await wait("source document for \(name)") {
      await document(source, runtime: runtime)?["href"] as? String == originA.absoluteString
    }
    let prior = Set(
      host.contexts.values.flatMap { $0.store.session.spaces.flatMap(\.tabs) }.map(\.id))
    let gestureResult: String?
    if elementID == "plain" {
      gestureResult = await gesture(source, script: "document.getElementById('plain').click()")
    } else {
      gestureResult = await click(source, elementID: elementID)
      try expect(gestureResult != nil, "NATIVE NEEDED: trusted offscreen click for \(name)")
    }
    let destination = try await destinationTab(
      name: name, source: source, ownerID: ownerID, prior: prior, host: host,
      gestureResult: gestureResult)
    let createdTabs = Set(
      host.contexts.values.flatMap { $0.store.session.spaces.flatMap(\.tabs) }.map(\.id)
    ).subtracting(prior)
    try expect(
      Self.hasSingleDestinationTab(createdTabs, destination: destination),
      "\(name) creates exactly one destination tab")
    if elementID != "plain" {
      let clicked = try require(await document(source, runtime: runtime), "No source document")
      try expect(
        clicked["clicked"] as? String == elementID && clicked["trusted"] as? String == "true",
        "\(name) receives a trusted browser click")
    }
    let page = try require(await document(destination, runtime: runtime), "No destination document")
    let destinationURL = (page["href"] as? String).flatMap(URL.init(string:))
    try expect(
      ReloadWindowProbeEvidence.isCrossSiteLoopbackNavigation(
        source: originA, destination: destinationURL?.absoluteString),
      "\(name) navigates between distinct loopback sites")
    try expect(
      page["marker"] as? String == "Cross-site destination loaded",
      "\(name) reaches the second origin")
    try expect(
      host.contexts.values.allSatisfy { $0.store.rendererFailures.isEmpty },
      "\(name) does not show Shaar's failed-page view")
    try expect(NSApp.windows.allSatisfy { !$0.isVisible }, "\(name) keeps all windows hidden")
    return "\(name) reaches the second origin without a failed page or visible window"
  }

  private func destinationTab(
    name: String, source: UUID, ownerID: UUID, prior: Set<UUID>, host: NativeBrowserHost,
    gestureResult: String?
  ) async throws -> UUID {
    var found: UUID?
    do {
      try await wait("\(name) destination") {
        for context in host.contexts.values {
          for tab in context.store.session.spaces.flatMap(\.tabs)
          where Self.isDestinationCandidate(
            tabID: tab.id, sourceID: source, prior: prior,
            candidateOwnerID: context.id, ownerID: ownerID, requiresNewTab: name != "plain")
          {
            if let page = await document(tab.id, runtime: runtime),
              (page["href"] as? String)?.contains("/cross-site-b") == true
            {
              found = tab.id
              return true
            }
          }
        }
        return false
      }
    } catch {
      let sourceDocument = await document(source, runtime: runtime)
      let models = host.contexts.values.flatMap { context in
        context.store.session.spaces.flatMap(\.tabs).map {
          "\($0.id):\($0.url.absoluteString):\(context.store.rendererFailures[$0.id]?.status ?? "ok")"
        }
      }
      throw Failure(
        "\(name) page-created tab was not adopted; gesture=\(gestureResult ?? "nil") source=\(sourceDocument ?? [:]) tabs=\(models)"
      )
    }
    return try require(found, "\(name) did not produce a destination tab")
  }

  private func gesture(_ id: UUID, script: String) async -> String? {
    await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: id.uuidString, script: "(()=>{\(script);return {clicked:true};})()")
      {
        continuation.resume(returning: $0)
      }
    }
  }

  private func click(_ id: UUID, elementID: String) async -> String? {
    let clicked: Bool = await withCheckedContinuation { continuation in
      runtime.clickProbeElement(inTabID: id.uuidString, elementID: elementID) {
        continuation.resume(returning: $0)
      }
    }
    return clicked ? "offscreen click sent" : nil
  }

  private func document(_ id: UUID, runtime: ARCChromiumRuntime) async -> [String: Any]? {
    let value: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: id.uuidString,
        script:
          "({href:location.href,marker:document.getElementById('destination')?.innerText||'',clicked:document.documentElement.dataset.clicked||'',trusted:document.documentElement.dataset.trusted||''})"
      ) { continuation.resume(returning: $0) }
    }
    return Self.parseDocumentJSON(value)
  }

  static func parseDocumentJSON(_ value: String?) -> [String: Any]? {
    guard let value, let data = value.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func wait(_ label: String, condition: () async -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 20 * ProbeTimeout.scale
    while ProcessInfo.processInfo.systemUptime < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out waiting for \(label)")
  }

  static func isDestinationCandidate(
    tabID: UUID, sourceID: UUID, prior: Set<UUID>,
    candidateOwnerID: UUID, ownerID: UUID, requiresNewTab: Bool
  ) -> Bool {
    guard candidateOwnerID == ownerID else { return false }
    if requiresNewTab { return tabID != sourceID && !prior.contains(tabID) }
    return tabID == sourceID || !prior.contains(tabID)
  }

  private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw Failure(message) }
    return value
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
  }

  /// Names the gate that rejected Reload so a hidden run can show it without a window.
  private func reloadRejection(
    _ owner: NativeBrowserContext, failure: RendererFailure, tab: UUID
  ) -> String {
    let store = owner.store
    let recorded = store.rendererFailures[tab]
    var reasons: [String] = []
    if store.session.selectedPage?.tab.id != tab {
      let selected = store.session.selectedPage?.tab.id.uuidString ?? "none"
      reasons.append("selected tab is \(selected)")
    }
    if recorded == nil {
      reasons.append("failure was cleared")
    } else if recorded?.id != failure.id {
      reasons.append("failure id changed")
    }
    if recorded?.profileID != store.session.selectedSpace.profileID {
      reasons.append("profile does not match the selected space")
    }
    if store.commandIsOpen { reasons.append("command palette is open") }
    if store.sheet != nil { reasons.append("a sheet is open") }
    if recorded?.reloading == true { reasons.append("reload is already running") }
    if store.onReloadPage == nil { reasons.append("reload handler is missing") }
    if owner.engine.isClosed { reasons.append("engine is closed") }
    if runtime.isQuitting { reasons.append("engine is quitting") }
    if !runtime.isWindowOpenID(owner.nativeID) { reasons.append("engine window is closed") }
    if owner.engine.liveTabs.contains(tab) { reasons.append("tab is still marked live") }
    if let notice = owner.engine.notice, !notice.isEmpty { reasons.append(notice) }
    let detail = reasons.isEmpty ? "reload handler returned false" : reasons.joined(separator: "; ")
    return "Reload action accepts destroyed tab (\(detail))"
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  static func hasSingleDestinationTab(_ createdIDs: Set<UUID>, destination: UUID) -> Bool {
    createdIDs.count == 1 && createdIDs.contains(destination)
  }
}
