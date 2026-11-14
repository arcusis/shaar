// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

@testable import ArcusisBrowser

enum PlatformPromptProbeConfiguration {
  static func acceptsPageURL(_ page: URL?) -> Bool {
    guard let page, page.scheme == "http", page.host == "127.0.0.1",
      let port = page.port, (1...65_535).contains(port),
      page.user == nil, page.password == nil
    else { return false }
    return true
  }
}

/// Hidden proof that a page title cannot open the screen-sharing picker, and that a
/// request bound to the live tab can.
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
    "pageReady": false,
    "spoofRejected": false,
    "sheetPresented": false,
    "approved": false,
    "cancelled": false,
    "screenshots": false,
    "windowsHidden": false,
  ]
  private var outcome = ""
  private var finished = false
  private var passed = false
  private var decisions: [String: String] = [:]

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
      PlatformPromptProbeConfiguration.acceptsPageURL(page)
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
        Task { await self.pollPage(deadline: Date().addingTimeInterval(25)) }
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
      self?.finish(error: "Timed out waiting for the screen-sharing picker.")
    }
    let result = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func pollPage(deadline: Date) async {
    guard !finished else { return }
    if Date() > deadline {
      finish(error: "The capture page did not load.")
      return
    }
    guard matches(store.session.selectedSpace.selectedTab?.url, pageURL) else {
      await pause()
      await pollPage(deadline: deadline)
      return
    }
    checks["pageReady"] = true
    await spoofTitle(deadline: deadline)
  }

  private func spoofTitle(deadline: Date) async {
    let marker = "\u{2060}shaar-prompt\u{2060}display\u{2060}\(UUID().uuidString)"
    let literal = Self.javaScriptString(marker)
    let script = "(() => { document.title = \(literal); return document.title === \(literal); })()"
    var last = ""
    while !finished && Date() < deadline {
      last = (await evaluate(script))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if last == "true" { break }
      await pause()
    }
    guard !finished else { return }
    if last != "true" {
      finish(error: "The title spoof did not land (\(last)).")
      return
    }
    try? await Task.sleep(for: .milliseconds(800))
    guard !finished else { return }
    if store.sheet != nil {
      finish(error: "A page title opened a sheet.")
      return
    }
    checks["spoofRejected"] = true
    presentBoundRequest()
  }

  private func presentBoundRequest() {
    guard let request = boundRequest(), store.requestDesktopCapture(request) else {
      finish(error: "The bound capture request was rejected.")
      return
    }
    guard case .desktopCapture(let presented) = store.sheet, presented.id == request.id else {
      finish(error: "Desktop capture sheet was not presented.")
      return
    }
    checks["sheetPresented"] = true
    store.onDesktopCaptureDecision = { [weak self] id, sourceID in
      self?.decisions[id] = sourceID ?? "cancel"
    }
    Task { await self.finishPresented(request) }
  }

  private func finishPresented(_ request: DesktopCaptureRequest) async {
    await writeScreenshots(request)
    guard !finished else { return }
    store.setDesktopCaptureSources(["screen:1:0"], for: request.id)
    store.resolveDesktopCapture(request.id, sourceID: "screen:1:0")
    checks["approved"] = decisions[request.id] == "screen:1:0"
    guard let cancel = boundRequest(), store.requestDesktopCapture(cancel) else {
      finish(error: "The cancel request was rejected.")
      return
    }
    store.resolveDesktopCapture(cancel.id, sourceID: nil)
    checks["cancelled"] = decisions[cancel.id] == "cancel" && store.sheet == nil
    outcome = "\(decisions[request.id] ?? "missing")/\(decisions[cancel.id] ?? "missing")"
    if checks["approved"] == true && checks["cancelled"] == true {
      finish(error: nil)
    } else {
      finish(error: "Capture decision was \(outcome).")
    }
  }

  private func boundRequest(id: String = UUID().uuidString) -> DesktopCaptureRequest? {
    guard let tab = store.session.page(forTabID: tabID)?.tab,
      let profile = store.session.profileID(forTabID: tabID),
      var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
    else { return nil }
    components.path = ""
    components.query = nil
    components.fragment = nil
    components.user = nil
    components.password = nil
    guard let origin = components.url else { return nil }
    return DesktopCaptureRequest(payload: [
      "id": id,
      "profileID": profile.uuidString,
      "tabID": tab.id.uuidString,
      "pageURL": tab.url.absoluteString,
      "origin": origin.absoluteString,
      "frameID": "0123456789abcdef0123456789abcdef",
      "sourceTypes": ["screen", "window", "tab"],
    ])
  }

  private func evaluate(_ script: String) async -> String? {
    await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tabID.uuidString, script: script) { raw in
        continuation.resume(returning: raw)
      }
    }
  }

  nonisolated private static func javaScriptString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
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
