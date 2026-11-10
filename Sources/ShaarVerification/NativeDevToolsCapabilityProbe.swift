// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Exercises the verification harness and its bundled engine with a disposable,
/// never-ordered browser window. The caller supplies an authored loopback page.
@MainActor enum NativeDevToolsCapabilityProbe {
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
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: false)
        host.detach()
        return code
      }
    } catch {
      write(["error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func inspect(
    host: NativeBrowserHost, pageURL: URL, outputURL: URL
  ) async {
    defer { host.events.quit() }
    do { try host.restore() } catch {
      write(["error": error.localizedDescription], to: outputURL)
      return
    }
    guard let context = host.contexts.values.first else {
      write(["error": "No hidden browser context"], to: outputURL)
      return
    }
    context.store.perform(.open(pageURL))
    for _ in 0..<100 {
      if let target = context.engine.siteControlTarget,
        target.url == pageURL,
        context.engine.pages[target.tabID]?.loading == false
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let target = context.engine.siteControlTarget,
      target.url == pageURL,
      context.engine.pages[target.tabID]?.loading == false
    else {
      write(["error": "No committed web page"], to: outputURL)
      return
    }
    _ = context.engine.showDeveloperTools(for: target)
    guard let shell = context.engine.shaarDevTools[target.tabID] else {
      write(["error": "No DevTools shell"], to: outputURL)
      return
    }
    for _ in 0..<100 {
      if shell.streamAvailable || shell.nativeStreamFailure != nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    if shell.streamAvailable {
      for _ in 0..<50 {
        if shell.phase2.available || shell.nativePhase2Failure != nil { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    write(
      [
        "normalBundle": Bundle.main.bundleIdentifier ?? "",
        "allWindowsHidden": host.contexts.values.allSatisfy { !$0.window.isVisible },
        "streamAvailable": shell.streamAvailable,
        "phase2Available": shell.phase2.available,
        "domAvailable": shell.dom.available,
        "viewportsAvailable": shell.viewports.available,
        "nativeFailure": shell.nativeStreamFailure ?? "",
        "phase2Failure": shell.nativePhase2Failure ?? "",
        "targetURL": target.url.absoluteString,
        "pageLoading": context.engine.pages[target.tabID]?.loading ?? true,
      ], to: outputURL)
    shell.close()
  }

  private static func write(_ report: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
    else { return }
    try? data.write(to: url, options: .atomic)
  }
}
