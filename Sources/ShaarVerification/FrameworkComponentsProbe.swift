// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Reads React, Vue, and Angular fixtures through the production Components panel.
/// Windows stay hidden for the whole run.
@MainActor final class FrameworkComponentsProbe {
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
      let originalSpace = store.session.selectedSpaceID
      guard
        store.createSpace(
          name: "Framework Components", sharingProfile: store.session.selectedSpace.profileID,
          tint: .ocean)
      else { throw Failure("Could not create isolated Components Space") }
      let space = store.session.selectedSpaceID
      defer {
        store.perform(.space(originalSpace))
        _ = store.removeSpace(space)
      }
      try await inspect(
        "/framework-components/react", framework: .react,
        names: ["App", "Header", "Counter"], highlight: true)
      try await inspect(
        "/framework-components/vue", framework: .vue,
        names: ["App", "Header", "Counter"], highlight: false)
      try await inspect(
        "/framework-components/angular", framework: .angular,
        names: ["App", "Header", "Counter"], highlight: false)
      try await inspectPlain()
      guard
        !ShaarFrameworkAccess.allows(
          url: URL(string: "https://example.com/")!, enabledHost: nil)
      else { throw Failure("Remote pages must stay off until the user enables that host") }
      checks.append("Remote pages stay off until that host is enabled")
      try expectHidden()
      try writeReport(error: nil)
      return checks
    } catch {
      try? writeReport(error: error)
      throw error
    }
  }

  private func inspect(
    _ path: String, framework: ShaarFrameworkKind, names: [String], highlight: Bool
  ) async throws {
    let shell = try await open(path)
    shell.section = .components
    await shell.framework.refresh()
    try await wait("\(framework.rawValue) tree") {
      shell.framework.rows.map(\.name) == names && shell.framework.framework == framework
    }
    let counter = shell.framework.nodes.first { $0.name == "Counter" }
    guard let counter, counter.props.contains(where: { $0.name == "start" && $0.value == "0" })
    else {
      throw Failure("\(framework.rawValue) Counter props were \(shell.framework.nodes)")
    }
    guard counter.state.contains(where: { $0.value == "2" }) else {
      throw Failure("\(framework.rawValue) Counter state was \(counter.state)")
    }
    if highlight { try await proveHighlight(shell, id: counter.id) }
    checks.append("\(framework.title) fixture shows App, Header, and Counter")
  }

  private func inspectPlain() async throws {
    let shell = try await open("/framework-components/plain")
    shell.section = .components
    await shell.framework.refresh()
    try await wait("plain page") {
      shell.framework.inspected && shell.framework.rows.isEmpty && shell.framework.failure == nil
        && shell.framework.framework == nil
    }
    checks.append("Plain page has no component tree")
  }

  private func proveHighlight(_ shell: ShaarDevToolsModel, id: String) async throws {
    guard let inspector = engine.inspectors[shell.target.tabID] else {
      throw Failure("Components inspector is missing")
    }
    await shell.framework.highlight(id)
    await shell.framework.highlight(id)
    let marked = try await inspector.evaluate(
      "document.getElementById('shaar-framework-highlight') && document.getElementById('shaar-framework-highlight').getAttribute('data-shaar-highlight')"
    )
    guard marked as? String == id else {
      throw Failure("Highlight did not mark component \(id): \(String(describing: marked))")
    }
    if let stale = ShaarFrameworkPageScript.highlightExpression(id: nil, epoch: 1) {
      _ = try await inspector.evaluate(stale)
    }
    let kept = try await inspector.evaluate(
      "document.getElementById('shaar-framework-highlight') != null")
    guard kept as? Bool == true else { throw Failure("A stale highlight clear removed the overlay") }
    await shell.framework.highlight(nil)
    let gone = try await inspector.evaluate(
      "document.getElementById('shaar-framework-highlight') == null")
    guard gone as? Bool == true else { throw Failure("Clearing the highlight left the overlay") }
    checks.append("Hover highlight draws on the component and a later clear removes it")
  }

  private func open(_ path: String) async throws -> ShaarDevToolsModel {
    let page = DevToolsPanelResults.fixtureURL(path, from: fixture)
    store.perform(.open(page))
    guard let tab = store.session.selectedPage?.tab.id else {
      throw Failure("No Components fixture tab for \(path)")
    }
    try await wait("\(path) ready") {
      self.engine.liveTabs.contains(tab) && self.engine.pages[tab]?.loading == false
        && self.engine.siteControlTarget?.url.path == path
        && self.engine.runtime.view(forTabID: tab.uuidString)?.superview != nil
    }
    try await Task.sleep(for: .milliseconds(150))
    guard let target = engine.siteControlTarget, target.tabID == tab,
      engine.showDeveloperTools(for: target),
      let shell = engine.shaarDevTools[tab]
    else { throw Failure("Components panel did not open for \(path)") }
    return shell
  }

  private func expectHidden() throws {
    guard NSApp.windows.allSatisfy({ !$0.isVisible }) else {
      throw Failure("Components probe opened a visible window")
    }
  }

  private func wait(_ message: String, attempts: Int = 80, _ condition: () -> Bool) async throws {
    for _ in 0..<attempts {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out: \(message)")
  }

  private func writeReport(error: Error?) throws {
    let report: [String: Any] = [
      "phase": phase,
      "hidden": NSApp.windows.allSatisfy { !$0.isVisible },
      "checks": checks,
      "error": error?.localizedDescription ?? NSNull(),
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appending(path: "\(phase)-framework-components.json"), options: .atomic)
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
