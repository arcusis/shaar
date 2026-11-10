// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Proves the agent packet through the hidden verification harness. The window stays offscreen.
@MainActor enum AgentCopyProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.host == "127.0.0.1", pageURL.scheme == "http" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    let route = Route()
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe, keyWindow: { route.window })
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task {
          await inspect(host: host, route: route, pageURL: pageURL, outputURL: outputURL)
        }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func inspect(
    host: NativeBrowserHost, route: Route, pageURL: URL, outputURL: URL
  ) async {
    defer { host.events.quit() }
    var failures: [String] = []
    do { try host.restore() } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      write(["passed": false, "error": "No hidden browser context"], to: outputURL)
      return
    }
    route.window = context.window
    let directory = outputURL.deletingLastPathComponent()
    context.store.perform(.open(pageURL))
    let opened = await wait(300) { pageReady(context, page: pageURL) }
    guard opened else {
      write(
        report(failures: ["No committed local page"], context: context, host: host), to: outputURL)
      return
    }
    let fixtureReady = await pageFlag(context, "window.__agentCopyReady === true")
    if !fixtureReady {
      failures.append("The local page did not finish its fixture request")
    }
    _ = capture(context, to: directory.appending(path: "before.png"))
    host.perform(.agentPacket)
    guard let session = context.store.agentCopy else {
      failures.append("The View menu did not open the agent packet")
      write(report(failures: failures, context: context, host: host), to: outputURL)
      return
    }
    let panelFound = find(identifier: "agent-copy.panel", in: context.hosting) != nil
    guard let first = await waitPacket(session) else {
      failures.append(session.failure ?? unfinished(session))
      await session.shutdown()
      write(
        report(failures: failures, context: context, host: host, panel: panelFound), to: outputURL)
      return
    }
    note(first, failures: &failures, label: "page")
    if !first.markdown.contains("none recorded (no buffer was running)") {
      failures.append("The first packet did not say the console buffer was off")
    }
    if !first.markdown.contains("/missing") && !first.markdown.contains("404") {
      failures.append("The first packet missed the failed request")
    }
    do {
      try await session.installDiagnostics()
      _ = try await session.evaluatePage(
        """
        (async () => {
          console.error("agent-copy-marker");
          try {
            await fetch("/missing-again", {headers:{Authorization:"Bearer fixture-token"}});
          } catch (error) {}
          return "ok";
        })()
        """)
    } catch {
      failures.append("Diagnostics did not install")
    }
    session.rebuild()
    if let second = await waitPacket(session) {
      note(second, failures: &failures, label: "recorded")
      if !second.markdown.contains("agent-copy-marker") {
        failures.append("The recorded packet missed the console marker")
      }
      if !second.markdown.contains("[redacted]") {
        failures.append("The recorded packet did not redact the request")
      }
    } else {
      failures.append(session.failure ?? "The recorded packet did not finish")
    }
    _ = try? await session.evaluatePage(
      "document.getElementById('card')&&document.getElementById('card').focus(); true")
    session.preferredSelector = nil
    session.setScope(.element)
    var element = await waitPacket(session)
    if element?.markdown.contains("Card title") != true {
      session.preferredSelector = "#card"
      session.rebuild()
      element = await waitPacket(session)
    }
    if let element {
      note(element, failures: &failures, label: "element")
      if !element.markdown.contains("Card title") {
        failures.append("The element packet missed the title")
      }
      if !element.markdown.contains("/src/Card.tsx:12") {
        failures.append("The element packet missed the source location")
      }
      if !element.markdown.contains("color: blue") {
        failures.append("The element packet missed the winning color")
        failures.append(cssExcerpt(element.markdown))
      }
      if element.markdown.contains("color: red") {
        failures.append("The element packet kept the losing color")
        failures.append(cssExcerpt(element.markdown))
      }
      if element.screenshotBytes <= 0 { failures.append("The element screenshot was empty") }
    } else {
      failures.append(session.failure ?? "The element packet did not finish")
    }
    let board = NSPasteboard(name: NSPasteboard.Name("shaar-agent-copy-\(UUID().uuidString)"))
    session.pasteboard = board
    let pressed = press(identifier: "agent-copy.copy", in: context.hosting)
    if !pressed {
      _ = await session.copyNow()
    } else {
      _ = await wait(20) { session.didCopy }
      if !session.didCopy { _ = await session.copyNow() }
    }
    let copied = board.string(forType: .string) ?? ""
    if !session.didCopy || !copied.contains("# Agent packet") {
      failures.append("Copy did not reach the named pasteboard")
    }
    if copied.contains("fixture-token") || copied.contains("secret-value") {
      failures.append("The pasteboard held a fixture secret")
    }
    await session.handoffNow()
    if !session.bridgeInvoked { failures.append("Hand to agent did not call the agent bridge") }
    let bridgeError = session.bridgeError ?? ""
    if bridgeError.contains("ws://") || bridgeError.contains("fixture-token") {
      failures.append("The bridge note held a secret or endpoint")
    }
    try? await Task.sleep(for: .milliseconds(200))
    context.hosting.layoutSubtreeIfNeeded()
    _ = capture(context, to: directory.appending(path: "after.png"))
    await session.shutdown()
    context.store.perform(.open(URL(string: "https://example.com/")!))
    let exampleReady = await wait(200) { pageReady(context, host: "example.com") }
    if !exampleReady {
      failures.append("example.com did not load")
    } else {
      host.perform(.agentPacket)
      if let exampleSession = context.store.agentCopy,
        let example = await waitPacket(exampleSession)
      {
        note(example, failures: &failures, label: "example")
        if !example.markdown.contains("example.com") {
          failures.append("The example.com packet missed the page")
        }
        await exampleSession.shutdown()
      } else {
        failures.append(context.store.agentCopy?.failure ?? "The example.com packet did not finish")
        await context.store.agentCopy?.shutdown()
      }
    }
    var receipt = report(failures: failures, context: context, host: host, panel: panelFound)
    receipt["invokedCopy"] = session.didCopy
    receipt["bridgeInvoked"] = session.bridgeInvoked
    receipt["bridgeEnabled"] = session.bridgeEnabled
    receipt["bridgeError"] = bridgeError
    receipt["passed"] = failures.isEmpty
    write(receipt, to: outputURL)
  }

  private static func unfinished(_ session: AgentCopySession) -> String {
    if session.busy { return "The first packet did not finish (still building)" }
    return "The first packet did not finish"
  }

  private static func cssExcerpt(_ markdown: String) -> String {
    guard let start = markdown.range(of: "## Winning CSS") else {
      return "Winning CSS section missing"
    }
    let rest = markdown[start.upperBound...]
    let end = rest.range(of: "\n## ")
    let section = end.map { rest[..<$0.lowerBound] } ?? rest
    let text = section.replacingOccurrences(of: "fixture-token", with: "[redacted]")
    if text.count <= 500 { return "Winning CSS:" + text }
    return "Winning CSS:" + text.prefix(500)
  }

  private static func note(_ packet: AgentCopyBuilt, failures: inout [String], label: String) {
    if packet.markdown.contains("fixture-token") || packet.markdown.contains("secret-value") {
      failures.append("The \(label) packet contained a fixture secret")
    }
    if packet.markdown.contains("iVBOR") {
      failures.append("The \(label) packet embedded the screenshot")
    }
  }

  private static func pageFlag(_ context: NativeBrowserContext, _ expression: String) async -> Bool
  {
    for _ in 0..<100 {
      if let value = try? await evaluate(expression, context: context), value as? Bool == true {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private static func evaluate(_ expression: String, context: NativeBrowserContext) async throws
    -> Any?
  {
    guard let target = context.engine.siteControlTarget else { return nil }
    let connection = InspectorConnection(engine: context.engine)
    guard connection.begin(target) else { return nil }
    let result = try await connection.call(
      "Runtime.evaluate",
      params: ["expression": expression, "returnByValue": true, "awaitPromise": true],
      target: target)
    return (result["result"] as? [String: Any])?["value"]
  }

  private static func waitPacket(_ session: AgentCopySession) async -> AgentCopyBuilt? {
    for _ in 0..<200 {
      if let packet = session.packet, !session.busy { return packet }
      if let failure = session.failure, !session.busy, session.packet == nil {
        _ = failure
        return nil
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return session.busy ? nil : session.packet
  }

  private static func wait(_ attempts: Int, until ready: () -> Bool) async -> Bool {
    for _ in 0..<attempts {
      if ready() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return ready()
  }

  private static func pageReady(_ context: NativeBrowserContext, page: URL) -> Bool {
    guard let target = context.engine.siteControlTarget, !loading(context, target) else {
      return false
    }
    return target.url.host == page.host
      && (target.url.path == page.path || target.url.path == page.path + "/")
  }

  private static func pageReady(_ context: NativeBrowserContext, host: String) -> Bool {
    guard let target = context.engine.siteControlTarget, !loading(context, target) else {
      return false
    }
    return target.url.host?.lowercased() == host
  }

  private static func loading(_ context: NativeBrowserContext, _ target: SiteControlTarget) -> Bool
  {
    context.engine.pages[target.tabID]?.loading != false
  }

  private static func report(
    failures: [String], context: NativeBrowserContext, host: NativeBrowserHost, panel: Bool = false
  ) -> [String: Any] {
    [
      "passed": false,
      "failures": failures,
      "panelInHierarchy": panel,
      "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
      "targetURL": context.engine.siteControlTarget?.url.absoluteString ?? "",
    ]
  }

  private static func capture(_ context: NativeBrowserContext, to url: URL) -> Bool {
    let view = context.hosting
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 1, view.bounds.height > 1,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
    do {
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private static func press(identifier: String, in view: NSView) -> Bool {
    guard let node = find(identifier: identifier, in: view) else { return false }
    if let button = node as? NSButton, button.isEnabled {
      button.performClick(nil)
      return true
    }
    if let hosted = node as? NSView { return hosted.accessibilityPerformPress() }
    if let element = node as? NSAccessibilityElement { return element.accessibilityPerformPress() }
    return false
  }

  private static func find(identifier: String, in object: Any, seen: Set<ObjectIdentifier> = [])
    -> NSObject?
  {
    guard let node = object as? NSObject else { return nil }
    let token = ObjectIdentifier(node)
    if seen.contains(token) { return nil }
    var next = seen
    next.insert(token)
    if identifierOf(node) == identifier { return node }
    for child in children(of: node) {
      if let found = find(identifier: identifier, in: child, seen: next) { return found }
    }
    return nil
  }

  private static func identifierOf(_ object: NSObject) -> String? {
    if let view = object as? NSView { return view.accessibilityIdentifier() }
    if let element = object as? NSAccessibilityElement { return element.accessibilityIdentifier() }
    return nil
  }

  private static func children(of object: NSObject) -> [Any] {
    if let view = object as? NSView {
      var result = view.accessibilityChildren() ?? []
      result.append(contentsOf: view.subviews)
      return result
    }
    if let element = object as? NSAccessibilityElement {
      return element.accessibilityChildren() ?? []
    }
    return []
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}

private final class Route {
  weak var window: NSWindow?
}
