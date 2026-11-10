// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@testable import ArcusisBrowser

/// Hidden proof that getDisplayMedia presents the Shaar screen-sharing picker.
@MainActor
final class PlatformPromptProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let store: BrowserStore
  private let tabID: UUID
  private let output: URL
  private let dataRoot: URL
  private let pageURL: URL
  private var checks: [String: Bool] = [
    "scriptInstalled": false,
    "trustedClick": false,
    "sheetPresented": false,
    "cancelled": false,
    "screenshots": false,
    "windowsHidden": false,
  ]
  private var outcome = ""
  private var finished = false
  private var passed = false
  private var clicked = false

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }
    let framework = URL(filePath: try value(after: "--probe-framework"))
    guard let executable = Bundle.main.executableURL,
      ShaarFirstTabProbe.isBundledFramework(framework, for: executable)
    else {
      throw Failure(
        "The platform prompt probe requires Shaar Verification.app and its bundled Chromium framework."
      )
    }
    guard let page = URL(string: try value(after: "--probe-url")),
      page.scheme == "http", page.host == "127.0.0.1"
    else { throw Failure("The platform prompt probe requires an authored loopback page.") }
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    pageURL = page
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    self.store = store
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
      let probe = try PlatformPromptProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(
        Data("Platform prompt probe: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
        Task { await self.pollInstalled(deadline: Date().addingTimeInterval(25)) }
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
      self?.finish(error: "Timed out waiting for the screen sharing picker.")
    }
    let result = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func pollInstalled(deadline: Date) async {
    guard !finished else { return }
    if Date() > deadline {
      finish(error: "Page prompt script was not installed.")
      return
    }
    guard matches(store.session.selectedSpace.selectedTab?.url, pageURL) else {
      await pause()
      await pollInstalled(deadline: deadline)
      return
    }
    let state = await readPage()
    guard !finished else { return }
    if state.installed {
      checks["scriptInstalled"] = true
      click()
    } else {
      await pause()
      await pollInstalled(deadline: deadline)
    }
  }

  private func click() {
    guard !clicked else { return }
    clicked = true
    runtime.submitTrustedProbeClick(inTabID: tabID.uuidString, elementID: "parity-action") {
      [weak self] ok in
      guard let self, !self.finished else { return }
      guard ok else {
        self.finish(error: "Trusted click did not land.")
        return
      }
      self.checks["trustedClick"] = true
      Task { await self.pollSheet(deadline: Date().addingTimeInterval(8)) }
    }
  }

  private func pollSheet(deadline: Date) async {
    guard !finished else { return }
    if case .desktopCapture(let request) = store.sheet {
      checks["sheetPresented"] = true
      await writeScreenshots(request)
      store.resolveDesktopCapture(request.id, sourceID: nil)
      await pollOutcome(deadline: Date().addingTimeInterval(6))
      return
    }
    if Date() > deadline {
      finish(error: "Desktop capture sheet was not presented. Outcome: \(outcome).")
      return
    }
    let state = await readPage()
    if !state.outcome.isEmpty { outcome = state.outcome }
    await pause()
    await pollSheet(deadline: deadline)
  }

  private func pollOutcome(deadline: Date) async {
    guard !finished else { return }
    let state = await readPage()
    guard !finished else { return }
    if !state.outcome.isEmpty { outcome = state.outcome }
    if state.outcome == "NotAllowedError" {
      checks["cancelled"] = true
      finish(error: nil)
      return
    }
    if Date() > deadline {
      finish(error: "Screen sharing did not reject after cancel. Outcome: \(outcome).")
      return
    }
    await pause()
    await pollOutcome(deadline: deadline)
  }

  private func readPage() async -> (installed: Bool, outcome: String) {
    let script =
      "({installed: window.__shaarPrompts === true, outcome: window.__shaarCaptureOutcome || ''})"
    let tab = tabID.uuidString
    return await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab, script: script) { raw in
        continuation.resume(returning: Self.pageState(raw))
      }
    }
  }

  nonisolated private static func pageState(_ raw: String?) -> (installed: Bool, outcome: String) {
    guard let raw, let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (false, "") }
    let installed = (object["installed"] as? NSNumber)?.boolValue ?? false
    return (installed, object["outcome"] as? String ?? "")
  }

  private func pause() async {
    try? await Task.sleep(for: .milliseconds(200))
  }

  private func writeScreenshots(_ request: DesktopCaptureRequest) async {
    let before = DesktopCapturePickerContent(
      request: request, sources: [], loading: true, error: nil, onSelect: { _ in }, onCancel: {})
    let sources = [
      DesktopCaptureSource(
        id: "tab:\(tabID.uuidString):0", name: "Display capture", kind: .tab, isRequestingTab: true),
      DesktopCaptureSource(id: "window:4:0", name: "Notes", kind: .window),
      DesktopCaptureSource(id: "screen:1:0", name: "Main Display", kind: .display),
    ]
    let after = DesktopCapturePickerContent(
      request: request, sources: sources, loading: false, error: nil, onSelect: { _ in },
      onCancel: {})
    do {
      try await render(before, name: "picker-before.png")
      try await render(after, name: "picker-after.png")
      checks["screenshots"] = true
    } catch {
      checks["screenshots"] = false
    }
  }

  private func render<V: View>(_ view: V, name: String) async throws {
    let size = NSSize(width: 480, height: 420)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw Failure("Picker capture render failed.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw Failure("Picker capture encode failed.")
    }
    try png.write(to: output.deletingLastPathComponent().appending(path: name), options: .atomic)
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    let hidden = windowsHidden()
    checks["windowsHidden"] = hidden
    passed = error == nil && hidden && checks.values.allSatisfy { $0 }
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "platform-prompts",
      "passed": passed,
      "checks": checks,
      "outcome": outcome,
      "requestedURL": pageURL.absoluteString,
      "allWindowsHidden": hidden,
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
      FileHandle.standardError.write(Data("Platform prompt report failed: \(error)\n".utf8))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      for context in self.host.contexts.values {
        _ = self.runtime.closeWindowID(context.nativeID)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.runtime.quit()
      }
    }
  }

  private func windowsHidden() -> Bool {
    guard let windowID = runtime.windowID(forTabID: tabID.uuidString),
      let window = runtime.window(forID: windowID), !window.isVisible
    else { return false }
    return NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private func matches(_ actual: URL?, _ requested: URL) -> Bool {
    ShaarFirstTabProbe.matchesRequestedURL(actual, requested: requested)
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
