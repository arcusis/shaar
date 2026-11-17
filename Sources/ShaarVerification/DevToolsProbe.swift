// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
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
    guard let target = engine.siteControlTarget,
      let inspected = runtime.view(forTabID: identity),
      let card = inspected.superview
    else { throw Failure("No selected page card") }
    try expect(
      engine.openChromiumDeveloperTools(for: target), "site-control action opens built-in DevTools")
    do {
      try await wait("DevTools docks inside the selected page card") {
        self.isDocked(identity, page: inspected, container: card)
      }
    } catch {
      throw Failure(
        "\(error.localizedDescription): \(Self.dockDescription(runtime, identity, inspected, card))"
      )
    }
    guard let tools = runtime.devToolsView(forTabID: identity) else {
      throw Failure("No DevTools view")
    }
    try expect(
      tools.superview === card && inspected.superview === card && card.subviews.last === inspected,
      "page and inspector share one stable native container")
    try expect(
      engine.runtime.window(forID: engine.windowID)?.isVisible == false,
      "opening DevTools never orders the probe window onscreen")
    let page = inspected
    try expect(!page.isHidden && !tools.isHidden, "selected native page and inspector are unhidden")
    let size = card.frame.size
    card.setFrameSize(NSSize(width: size.width - 60, height: size.height - 40))
    card.layoutSubtreeIfNeeded()
    let resizedCorrectly = isDocked(identity, page: page, container: card)
    card.setFrameSize(size)
    card.layoutSubtreeIfNeeded()
    try expect(resizedCorrectly, "engine layout keeps page and inspector bounded during resize")
    // Empty bounds crop the page to 60% until the frontend reports the splitter.
    // Remember the frame after that report, or the crop if it never arrives.
    let initial = try await rememberSettledDockFrame(identity, page: page, container: card)

    store.perform(.open(fixture.appending(path: "developer-tools-other")))
    guard let other = store.session.selectedPage?.tab.id else { throw Failure("No second tab") }
    do {
      try await wait("switching tabs hides the native page and inspector") {
        Self.notShown(page) && Self.notShown(tools)
      }
    } catch {
      throw Failure(
        "\(error.localizedDescription): pageHidden=\(page.isHiddenOrHasHiddenAncestor) pageWindow=\(page.window != nil) toolsHidden=\(tools.isHiddenOrHasHiddenAncestor) toolsWindow=\(tools.window != nil) toolsParent=\(tools.superview != nil)"
      )
    }
    try expect(
      runtime.devToolsView(forTabID: other.uuidString) == nil, "inspector remains scoped to its tab"
    )
    try expect(
      !engine.openChromiumDeveloperTools(for: target),
      "stale site-panel target cannot open another tab")
    store.perform(.tab(space: space, tab: tab))
    try await wait("returning restores the original inspector") {
      !tools.isHiddenOrHasHiddenAncestor && tools.superview === card
    }
    engine.toggleChromiumDeveloperTools()
    try await wait("shortcut action closes DevTools and restores the full page") {
      runtime.devToolsView(forTabID: identity) == nil && card.subviews.count == 1
        && page.frame == card.bounds && !page.isHidden
    }
    engine.toggleChromiumDeveloperTools()
    do {
      try await wait("reopening restores the engine's remembered dock layout") {
        self.isDocked(identity, page: page, container: card)
          && Self.rememberedDockFrameMatches(initial, page.frame)
      }
    } catch {
      let reopened = runtime.devToolsView(forTabID: identity)
      throw Failure(
        "\(error.localizedDescription): reopened=\(reopened != nil), docked=\(isDocked(identity, page: page, container: card)), initial=\(initial), page=\(page.frame), tools=\(reopened?.frame ?? .zero), \(Self.dockDescription(runtime, identity, page, card))"
      )
    }
    try expect(
      runtime.view(forTabID: identity) === page, "opening and closing preserve page-card identity")
    engine.toggleChromiumDeveloperTools()
    try await wait("DevTools closes before testing Inspect") {
      runtime.devToolsView(forTabID: identity) == nil && card.subviews.count == 1
        && page.frame == card.bounds && !page.isHidden
    }
    try expect(
      runtime.inspectProbeElement(inTabID: identity), "right click reaches the authored page")
    try await wait("engine Inspect command opens its docked frontend") {
      runtime.probeInspectFound && self.isDocked(identity, page: page, container: card)
    }
    checks.append("the enabled native Inspect context-menu command opens the built-in inspector")
    try expect(
      !runtime.showDevTools(forTabID: UUID().uuidString), "unknown tabs cannot open DevTools")
    for (path, framework) in [
      ("devmode-next", DevelopmentFramework.nextJS),
      ("devmode-vite", DevelopmentFramework.vite),
    ] {
      store.perform(.open(DevelopmentModeProbe.fixtureURL(fixture, path: path)))
      try await wait("Dev Mode detects \(framework.rawValue) on a hidden local fixture") {
        self.engine.detectedFramework == framework
          && self.engine.isDevelopmentPage
          && self.engine.siteControlTarget?.url.path == "/\(path)"
      }
    }
    store.perform(.space(returningTo))
    try expect(store.removeSpace(space), "closing the inspected tab removes its Space")
    try await wait("closing the inspected tab releases its page and inspector") {
      !self.engine.liveTabs.contains(tab) && runtime.devToolsView(forTabID: identity) == nil
        && card.subviews.isEmpty
    }
  }

  /// The pinned engine docks the frontend over the page container and crops the
  /// inspected page beside it. The page stays above the frontend.
  private func isDocked(_ identity: String, page: NSView, container: NSView) -> Bool {
    guard let tools = engine.runtime.devToolsView(forTabID: identity),
      tools.superview === container, page.superview === container,
      tools.frame.width > 0, tools.frame.height > 0, page.frame.width > 0, page.frame.height > 0
    else { return false }
    let bounds = container.bounds
    let tolerance = bounds.insetBy(dx: -1, dy: -1)
    let toolsCoverContainer =
      abs(tools.frame.width - bounds.width) <= 1
      && abs(tools.frame.height - bounds.height) <= 1
    return tolerance.contains(tools.frame) && tolerance.contains(page.frame)
      && toolsCoverContainer && page.frame.width + 1 < bounds.width
      && container.subviews.last === page
  }

  /// A background tab is not showing when its view is hidden or detached.
  private static func notShown(_ view: NSView) -> Bool {
    view.window == nil || view.isHiddenOrHasHiddenAncestor
  }

  private static func dockDescription(
    _ runtime: ARCChromiumRuntime, _ identity: String, _ page: NSView, _ container: NSView
  ) -> String {
    let tools = runtime.devToolsView(forTabID: identity)
    return
      "container=\(container.bounds) page=\(page.frame) pageParent=\(page.superview === container) tools=\(tools?.frame ?? .zero) toolsParent=\(tools?.superview === container) lastIsPage=\(container.subviews.last === page) subviews=\(container.subviews.count)"
  }

  static func rememberedDockFrameMatches(_ initial: NSRect, _ reopened: NSRect?) -> Bool {
    guard let reopened else { return false }
    return abs(reopened.minX - initial.minX) <= 1
      && abs(reopened.minY - initial.minY) <= 1
      && abs(reopened.width - initial.width) <= 1
      && abs(reopened.height - initial.height) <= 1
  }

  /// The pinned engine crops to 60% of the container while DevTools bounds are
  /// still empty. A later splitter update is the layout reopen has to restore.
  static func isEmptyBoundsPlaceholder(_ page: NSRect, in container: NSRect) -> Bool {
    guard container.width > 1, container.height > 1 else { return false }
    return abs(page.minX - container.minX) <= 1
      && abs(page.minY - container.minY) <= 1
      && abs(page.height - container.height) <= 1
      && abs(page.width - container.width * 0.6) <= 1
  }

  private func rememberSettledDockFrame(
    _ identity: String, page: NSView, container: NSView
  ) async throws -> NSRect {
    let budget = Int(150 * ProbeTimeout.scale)
    var latest: NSRect?
    for _ in 0..<budget {
      if isDocked(identity, page: page, container: container) {
        latest = page.frame
        if !Self.isEmptyBoundsPlaceholder(page.frame, in: container.bounds) {
          checks.append("DevTools applies the engine's dock bounds")
          return page.frame
        }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    if let latest {
      checks.append("DevTools keeps the initial dock crop")
      return latest
    }
    throw Failure("Timed out: DevTools applies the engine's dock bounds")
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
