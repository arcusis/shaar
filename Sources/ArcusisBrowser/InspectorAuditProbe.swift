// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Runs the Audits panel in the shipping executable against one loopback page.
/// The browser window stays hidden and the process does not become active.
@MainActor enum InspectorAuditProbe {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, pageURL.host == "127.0.0.1", pageURL.scheme == "http" else { return 2 }
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
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
        Task { await inspect(host: host, pageURL: pageURL, outputURL: outputURL) }
      }
      return withExtendedLifetime(host) {
        // A hidden window cannot present the login-keychain prompt, so the
        // page never commits. The engine test keychain keeps this probe off
        // the login keychain and lets the loopback document finish loading.
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["error": error.localizedDescription, "passed": false], to: outputURL)
      return 1
    }
  }

  private static func inspect(host: NativeBrowserHost, pageURL: URL, outputURL: URL) async {
    defer { host.events.quit() }
    do { try host.restore() } catch {
      write(["error": error.localizedDescription, "passed": false], to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      write(["error": "No hidden browser context", "passed": false], to: outputURL)
      return
    }
    context.store.perform(.open(pageURL))
    guard let target = await committedTarget(context: context, pageURL: pageURL) else {
      let selected = context.engine.siteControlTarget
      let loading = selected.flatMap { context.engine.pages[$0.tabID]?.loading }
      write(
        [
          "error": "No committed web page",
          "passed": false,
          "targetURL": selected?.url.absoluteString ?? "",
          "pageLoading": loading ?? true,
          "pageCount": context.engine.pages.count,
          "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
        ], to: outputURL)
      return
    }
    guard context.engine.showDeveloperTools(for: target),
      let shell = context.engine.shaarDevTools[target.tabID]
    else {
      write(["error": "Audits has no DevTools shell", "passed": false], to: outputURL)
      return
    }
    await waitForStream(shell)
    shell.section = .audits
    let summary = await auditSummary(shell)
    var report: [String: Any] = [
      "normalBundle": Bundle.main.bundleIdentifier ?? "",
      "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
      "resourceBundleStaged": Bundle.main.url(
        forResource: "ArcusisBrowser_ArcusisBrowser", withExtension: "bundle") != nil,
      "section": shell.section.rawValue,
      "targetURL": target.url.absoluteString,
    ]
    for (key, value) in summary { report[key] = value }
    write(report, to: outputURL)
    shell.close()
  }

  private static func committedTarget(
    context: NativeBrowserContext, pageURL: URL
  ) async -> SiteControlTarget? {
    for _ in 0..<300 {
      if let target = context.engine.siteControlTarget,
        target.url == pageURL,
        context.engine.pages[target.tabID]?.loading == false
      {
        return target
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private static func waitForStream(_ shell: ShaarDevToolsModel) async {
    for _ in 0..<100 {
      if shell.streamAvailable || shell.nativeStreamFailure != nil { return }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func auditSummary(_ shell: ShaarDevToolsModel) async -> [String: Any] {
    guard shell.pageAudit.inspector?.isOpen == true else {
      return ["passed": false, "failure": "Audits has no Inspector for this tab", "rules": []]
    }
    shell.pageAudit.setScope(.page)
    shell.pageAudit.run()
    for _ in 0..<300 {
      let finished =
        !shell.pageAudit.busy
        && (shell.pageAudit.report != nil || shell.pageAudit.failure != nil)
      if finished { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let report = shell.pageAudit.report else {
      return [
        "passed": false,
        "failure": shell.pageAudit.failure ?? "Audit did not finish",
        "violations": 0,
        "rules": [],
      ]
    }
    let rules = Array(Set(report.findings.map(\.ruleID))).sorted()
    let foundPlantedControls = rules.contains("button-name") && rules.contains("image-alt")
    let passed = foundPlantedControls && report.violations >= 2
    return [
      "passed": passed,
      "failure": shell.pageAudit.failure ?? "",
      "violations": report.violations,
      "rules": rules,
    ]
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}
