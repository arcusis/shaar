// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation

@testable import ArcusisBrowser

/// Exercises Chromium's own inspector in a hidden page card, including its native Inspect menu.
@MainActor
final class DevToolsProbe {
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
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
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    let returningTo = store.session.selectedSpaceID
    try expect(
      store.createSpace(
        name: "Developer Tools", sharingProfile: store.session.selectedSpace.profileID,
        tint: .ocean), "create an isolated DevTools Space")
    let space = store.session.selectedSpaceID
    store.perform(.open(fixture.appending(path: "developer-tools")))
    guard let tab = store.session.selectedPage?.tab.id else { throw Failure("No fixture tab") }
    let identity = tab.uuidString
    let runtime = engine.runtime
    try await wait("fixture page loads") {
      self.engine.liveTabs.contains(tab) && self.engine.pages[tab]?.loading == false
        && runtime.view(forTabID: identity)?.superview != nil
    }
    guard let target = engine.siteControlTarget, let card = runtime.view(forTabID: identity)
    else { throw Failure("No selected page card") }
    try expect(
      engine.showDeveloperTools(for: target), "site-control action opens built-in DevTools")
    try await wait("DevTools docks inside the selected page card") {
      self.isDocked(identity, in: card)
    }
    guard let tools = runtime.devToolsView(forTabID: identity) else {
      throw Failure("No DevTools view")
    }
    try expect(card.subviews.count == 2, "page and inspector share one stable native container")
    try expect(
      engine.runtime.window(forID: engine.windowID)?.isVisible == false,
      "opening DevTools never orders the probe window onscreen")
    guard let page = card.subviews.last, page !== tools else { throw Failure("No inspected page") }
    try expect(!page.isHidden && !tools.isHidden, "selected native page and inspector are unhidden")
    let initial = page.frame
    let size = card.frame.size
    card.setFrameSize(NSSize(width: size.width - 60, height: size.height - 40))
    card.layoutSubtreeIfNeeded()
    let resizedCorrectly = isDocked(identity, in: card)
    card.setFrameSize(size)
    card.layoutSubtreeIfNeeded()
    try expect(resizedCorrectly, "engine layout keeps page and inspector bounded during resize")

    store.perform(.open(fixture.appending(path: "developer-tools-other")))
    guard let other = store.session.selectedPage?.tab.id else { throw Failure("No second tab") }
    try await wait("switching tabs hides the native page and inspector") {
      page.isHidden && tools.isHidden && tools.isHiddenOrHasHiddenAncestor
    }
    try expect(
      runtime.devToolsView(forTabID: other.uuidString) == nil, "inspector remains scoped to its tab"
    )
    try expect(
      !engine.showDeveloperTools(for: target), "stale site-panel target cannot open another tab")
    store.perform(.tab(space: space, tab: tab))
    try await wait("returning restores the original inspector") {
      !tools.isHiddenOrHasHiddenAncestor && tools.superview === card
    }
    engine.toggleDeveloperTools()
    try await wait("shortcut action closes DevTools and restores the full page") {
      runtime.devToolsView(forTabID: identity) == nil && card.subviews.count == 1
        && page.frame == card.bounds && !page.isHidden
    }
    engine.toggleDeveloperTools()
    try await wait("reopening restores the engine's remembered dock layout") {
      self.isDocked(identity, in: card)
        && card.subviews.last?.frame == initial
    }
    try expect(
      runtime.view(forTabID: identity) === card, "opening and closing preserve page-card identity")
    engine.toggleDeveloperTools()
    try await wait("DevTools closes before testing Inspect") {
      runtime.devToolsView(forTabID: identity) == nil && card.subviews.count == 1
        && page.frame == card.bounds && !page.isHidden
    }
    try expect(
      runtime.inspectProbeElement(inTabID: identity), "right click reaches the authored page")
    try await wait("engine Inspect command opens its docked frontend") {
      runtime.probeInspectFound && self.isDocked(identity, in: card)
    }
    checks.append("the enabled native Inspect context-menu command opens the built-in inspector")
    try expect(
      !runtime.showDevTools(forTabID: UUID().uuidString), "unknown tabs cannot open DevTools")
    store.perform(.space(returningTo))
    try expect(store.removeSpace(space), "closing the inspected tab removes its Space")
    try await wait("closing the inspected tab releases its page and inspector") {
      !self.engine.liveTabs.contains(tab) && runtime.devToolsView(forTabID: identity) == nil
        && card.subviews.isEmpty
    }
  }

  private func isDocked(_ identity: String, in card: NSView) -> Bool {
    guard let tools = engine.runtime.devToolsView(forTabID: identity), tools.superview === card,
      let page = card.subviews.first(where: { $0 !== tools }), page.superview === card,
      tools.frame.width > 0, tools.frame.height > 0, page.frame.width > 0, page.frame.height > 0
    else { return false }
    let tolerance = card.bounds.insetBy(dx: -1, dy: -1)
    return tolerance.contains(tools.frame) && tolerance.contains(page.frame)
      && page.frame != card.bounds && card.subviews.last === page
  }

  private func wait(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<Int(150 * ProbeTimeout.scale) {
      if condition() {
        checks.append(message)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out: \(message)")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    let value: [String: Any] = [
      "phase": phase, "passed": error == nil, "checks": checks,
      "inspect": engine.runtime.probeInspectAudit ?? [:],
      "error": error?.localizedDescription as Any? ?? NSNull(),
      "scope": "Offscreen built-in DevTools layout and engine Inspect command; no physical input.",
    ]
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-developer-tools.json"), options: .atomic)
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
