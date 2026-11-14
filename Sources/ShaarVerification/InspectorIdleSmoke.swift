// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import CoreFoundation
import Foundation

@testable import ArcusisBrowser

enum InspectorIdleSmokeEvidence {
  static func acceptsPageURL(_ pageURL: URL?) -> Bool {
    guard let pageURL else { return false }
    return pageURL.scheme == "http" && pageURL.host == "127.0.0.1"
  }
}

enum InspectorIdlePollEvidence {
  static func stayedBackedOff(_ calls: Int) -> Bool {
    (2...12).contains(calls)
  }
}

/// Opens Inspector on one loopback page in the hidden verification app and counts
/// how often it reads the page once the selection has stopped changing.
@MainActor enum InspectorIdleSmoke {
  private static var verdictPassed = false

  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    verdictPassed = false
    guard let pageURL, InspectorIdleSmokeEvidence.acceptsPageURL(pageURL) else { return 2 }
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
        Task { await exercise(host: host, pageURL: pageURL, outputURL: outputURL) }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(withDataDirectory: root.appending(path: "Chromium"), testing: true)
        host.detach()
        return verdictPassed && code == 0 ? 0 : 1
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func exercise(host: NativeBrowserHost, pageURL: URL, outputURL: URL) async {
    defer { host.events.quit() }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      context.store.perform(.open(pageURL))
      guard let target = await committedTarget(context: context, pageURL: pageURL) else {
        throw Failure("Loopback page did not finish loading")
      }
      context.engine.toggleInspector(for: target)
      guard let model = context.engine.inspectors[target.tabID], model.isOpen else {
        throw Failure("Inspector did not open")
      }
      guard await scriptInstalled(model) else {
        throw Failure("Inspector page script did not install")
      }
      _ = try await model.evaluate(pollCounter)
      let locked =
        try await model.evaluate(
          "globalThis.__shaarInspectorV2.select(document.querySelector('main') || document.body) === true"
        ) as? Bool
      guard locked == true else { throw Failure("Inspector did not lock an element") }
      try await Task.sleep(for: .seconds(2))
      _ = try await model.evaluate("globalThis.__shaarInspectorPollCalls = 0; true")
      try await Task.sleep(for: .seconds(5))
      let calls = try await pollCalls(model)
      let hidden = host.contexts.values.allSatisfy { !$0.window.isVisible }
      let backedOff = InspectorIdlePollEvidence.stayedBackedOff(calls)
      verdictPassed = backedOff && hidden && model.isOpen
      write(
        [
          "passed": verdictPassed,
          "calls": calls,
          "locked": true,
          "allWindowsHidden": hidden,
          "inspectorOpen": model.isOpen,
          "targetURL": target.url.absoluteString,
        ], to: outputURL)
      model.close()
    } catch {
      let hidden = host.contexts.values.allSatisfy { !$0.window.isVisible }
      write(
        [
          "passed": false,
          "error": error.localizedDescription,
          "allWindowsHidden": hidden,
        ], to: outputURL)
    }
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

  private static func scriptInstalled(_ model: InspectorModel) async -> Bool {
    for _ in 0..<100 {
      if let installed = try? await model.evaluate("!!globalThis.__shaarInspectorV2") as? Bool,
        installed
      {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private static func pollCalls(_ model: InspectorModel) async throws -> Int {
    let value = try await model.evaluate("globalThis.__shaarInspectorPollCalls")
    guard let calls = pollCallCount(from: value) else {
      throw Failure("Inspector poll counter was missing or malformed")
    }
    return calls
  }

  static func pollCallCount(from value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let encoding = String(cString: number.objCType)
    let count =
      encoding == "f" || encoding == "d"
      ? Int(exactly: number.doubleValue)
      : Int(number.stringValue)
    guard let count, count >= 0 else { return nil }
    return count
  }

  private static let pollCounter = """
    (() => {
      const inspector = globalThis.__shaarInspectorV2;
      if (!inspector || inspector.__shaarPollWrapped) return true;
      const read = inspector.read.bind(inspector);
      globalThis.__shaarInspectorPollCalls = 0;
      inspector.read = () => {
        globalThis.__shaarInspectorPollCalls += 1;
        return read();
      };
      inspector.__shaarPollWrapped = true;
      return true;
    })()
    """

  private static func write(_ report: [String: Any], to url: URL) {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }
}
