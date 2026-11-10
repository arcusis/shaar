// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Hidden proof that idle discard asks the engine and leaves the tab in the window.
/// An engine without the lifecycle operation reports incapable and closes nothing.
@MainActor enum SleepingTabsProbe {
  private static let idleGap: TimeInterval = 3 * 60 * 60

  static func run(frameworkURL: URL, outputURL: URL) -> Int32 {
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    let report = Report()
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: root.appending(path: "workspace.json"),
          legacySessionURL: root.appending(path: "session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe)
      runtime.onReady = { [weak host] in
        guard let host else { return }
        NSApp.setActivationPolicy(.prohibited)
        Task { await exercise(host: host, runtime: runtime, outputURL: outputURL, report: report) }
      }
      return withExtendedLifetime(host) {
        let dataRoot = outputURL.deletingLastPathComponent().appending(path: "Chromium")
        let code = runtime.run(withDataDirectory: dataRoot, testing: true)
        host.detach()
        if report.passed && code == 0 { return 0 }
        return 1
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, outputURL: URL, report: Report
  ) async {
    var payload: [String: Any] = ["passed": false]
    defer {
      payload["allWindowsHidden"] = NSApp.windows.allSatisfy { !$0.isVisible }
      if payload["passed"] as? Bool == true && payload["allWindowsHidden"] as? Bool != true {
        payload["passed"] = false
        payload["error"] = "A window became visible"
      }
      report.passed = payload["passed"] as? Bool == true
      write(payload, to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      context.engine.sleepingTabs.policy = {
        SleepingTabsPolicy(enabled: true, timeout: 2 * 60 * 60, neverSleepHosts: [])
      }
      guard let original = context.store.session.selectedPage?.tab.id else {
        throw Failure("No restored tab")
      }
      let originalLive = await wait { context.engine.liveTabs.contains(original) }
      guard originalLive else {
        throw Failure(
          "The restored tab did not become live (live=\(context.engine.liveTabs.count))")
      }
      let opened = context.store.session.open(URL(string: "https://example.com")!)
      guard let opened else { throw Failure("Could not open a second tab") }
      context.engine.reconcile()
      let ready = await wait {
        context.engine.liveTabs.contains(opened) && context.engine.liveTabs.contains(original)
      }
      guard ready else {
        throw Failure(
          "The second tab did not become live (live=\(context.engine.liveTabs.count))")
      }
      let selected = context.store.session.selectedPage?.tab.id
      guard
        let background = context.store.session.spaces.flatMap(\.tabs).first(where: {
          $0.id != selected
        })?.id
      else { throw Failure("No background tab") }
      let capable: Bool = await withCheckedContinuation { continuation in
        runtime.probeTabLifecycle(forTabID: background.uuidString) { value in
          continuation.resume(returning: value)
        }
      }
      let before = context.store.session.spaces.flatMap(\.tabs).map(\.id)
      let now = Date()
      context.engine.suspendInactiveTabs(now: now)
      context.engine.suspendInactiveTabs(now: now.addingTimeInterval(idleGap))
      let after = context.store.session.spaces.flatMap(\.tabs).map(\.id)
      let stillListed = after.contains(background)
      let stillLive = context.engine.liveTabs.contains(background)
      let sleeping = context.store.sleepingTabIDs.contains(background)
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      let incapableLeftItAwake = capable || !sleeping
      let passed =
        stillListed && stillLive && hidden
        && before.contains(background) && incapableLeftItAwake
        && context.store.rendererFailures.isEmpty
      payload = [
        "passed": passed,
        "capable": capable,
        "backgroundStillListed": stillListed,
        "backgroundStillLive": stillLive,
        "sleeping": sleeping,
        "tabCount": after.count,
        "allWindowsHidden": hidden,
        "rendererFailures": context.store.rendererFailures.count,
      ]
    } catch {
      payload = ["passed": false, "error": error.localizedDescription]
    }
  }

  private static func wait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private static func write(_ value: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private final class Report {
    var passed = false
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
