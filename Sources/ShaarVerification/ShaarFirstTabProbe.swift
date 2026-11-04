// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Exercises the production backend selector and browser host without showing a window.
@MainActor
final class ShaarFirstTabProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let tabID: UUID
  private let output: URL
  private let dataRoot: URL
  private let pageURL = URL(string: "https://example.com")!
  private var finished = false
  private var passed = false
  private var navigationCommitted = false

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }

    guard
      BrowserBackendSelection.choose(
        environment: ProcessInfo.processInfo.environment, arguments: arguments) == .shaar
    else { throw Failure("The Shaar backend switch is required.") }

    let framework = URL(filePath: try value(after: "--probe-framework"))
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    let selected = try NativeBrowserHost.makeRuntime(
      frameworkURL: framework, environment: ProcessInfo.processInfo.environment,
      arguments: arguments)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    store.perform(.open(pageURL))
    guard let id = store.session.selectedSpace.selectedTabID else {
      throw Failure("The fresh workspace did not create its first tab.")
    }
    tabID = id
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let probe = try ShaarFirstTabProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(Data("Shaar first-tab probe: \(error)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    let previousCommitted = runtime.onDocumentCommitted
    runtime.onDocumentCommitted = { [weak self] id, profile in
      previousCommitted?(id, profile)
      guard let self, id == self.tabID.uuidString else { return }
      self.navigationCommitted = true
      DispatchQueue.main.async { [weak self] in self?.checkTab() }
    }
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
        self.checkTab()
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      self?.finish(error: "Timed out waiting for a native Shaar tab.")
    }
    let result = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func checkTab() {
    guard !finished else { return }
    let tab = tabID.uuidString
    if let view = runtime.view(forTabID: tab),
      let windowID = runtime.windowID(forTabID: tab),
      let window = runtime.window(forID: windowID),
      host.contexts.values.contains(where: { $0.engine.pages[tabID] != nil }),
      workspace.stores.values.contains(where: {
        matchesRequestedURL($0.session.selectedSpace.selectedTab?.url)
      }),
      navigationCommitted,
      !window.isVisible, NSApp.windows.allSatisfy({ !$0.isVisible })
    {
      finish(tabID: tab, nativeView: view)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.checkTab()
    }
  }

  private func matchesRequestedURL(_ actual: URL?) -> Bool {
    guard let actual, actual.scheme == pageURL.scheme, actual.host == pageURL.host,
      actual.query == pageURL.query, actual.fragment == pageURL.fragment
    else { return false }
    return actual.path == pageURL.path || (actual.path == "/" && pageURL.path.isEmpty)
  }

  private func finish(tabID: String? = nil, nativeView: NSView? = nil, error: String? = nil) {
    guard !finished else { return }
    finished = true
    passed = tabID != nil && nativeView != nil && error == nil
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "shaar-first-tab",
      "backend": "shaar",
      "passed": passed,
      "tabID": tabID ?? "",
      "nativeView": nativeView != nil,
      "navigationObserved": navigationCommitted,
      "requestedURL": pageURL.absoluteString,
      "allWindowsHidden": NSApp.windows.allSatisfy { !$0.isVisible },
      "error": error ?? "",
    ]
    do {
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      passed = false
      FileHandle.standardError.write(Data("Shaar first-tab report failed: \(error)\n".utf8))
    }
    if passed {
      for context in host.contexts.values { _ = runtime.closeWindowID(context.nativeID) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.runtime.quit()
      }
    } else {
      runtime.quit()
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
