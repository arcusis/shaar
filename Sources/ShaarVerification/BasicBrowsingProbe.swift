// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation

@testable import ArcusisBrowser

enum BasicBrowsingPageEvidence {
  static func isLive(_ value: Any?, expectedHost: String?) -> Bool {
    guard let page = value as? [String: Any],
      let href = page["href"] as? String,
      let ready = page["ready"] as? String,
      let text = page["text"] as? String,
      let current = URL(string: href)
    else { return false }
    return ready == "complete" && !text.isEmpty
      && (expectedHost == nil || current.host() == expectedHost)
  }
}

/// A short user-flow smoke in the normal browser store, backed by the disposable engine fixture.
@MainActor
struct BasicBrowsingProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let fixture: URL

  func run() async throws -> [String] {
    var checks: [String] = []
    let initialWindowCount = NSApp.windows.count
    let alphabet = "abcdefghijklmnopqrstuvwxyz"

    store.showCommand()
    store.commandQuery = store.session.selectedPage?.tab.url.absoluteString ?? ""
    store.commandQuery = ""
    for character in alphabet { store.commandQuery.append(character) }
    try expect(store.commandQuery == alphabet, "address bar accepts every letter a-z")
    checks.append("address bar accepts every letter a-z")
    try assertNoPicker(initialWindowCount)
    checks.append("address bar typing opens no menu or picker")
    store.dismissCommand()

    // Command-T routes through the same normal-window launcher action as the app shortcut.
    store.showCommand()
    for character in alphabet { store.commandQuery.append(character) }
    try expect(store.commandQuery == alphabet, "Command-T search accepts every letter a-z")
    checks.append("Command-T search accepts every letter a-z")
    try assertNoPicker(initialWindowCount)
    checks.append("Command-T typing opens no menu or picker")

    let searchText = "shaar basic browsing smoke"
    store.commandQuery = searchText
    guard
      let searchURL = NavigationInput.destination(
        for: searchText,
        searchEngine: store.preferences.searchEngine(for: store.session.selectedSpace.profileID))
    else { throw Failure("Search query did not produce a destination.") }
    store.acceptCommand()
    guard let searchTab = store.session.selectedSpace.selectedTabID else {
      throw Failure("Search did not open a tab.")
    }
    guard store.session.selectedSpace.selectedTab?.url == searchURL else {
      throw Failure("Search command did not navigate to its selected result.")
    }
    try await waitForLivePage(searchTab, expectedHost: searchURL.host())
    checks.append("normal window searches and lands on live results")

    var opened: [UUID] = []
    for name in ["smoke-one", "smoke-two", "smoke-three"] {
      let url = fixture.appending(path: name)
      store.perform(.open(url))
      guard let id = store.session.selectedSpace.selectedTabID else {
        throw Failure("Opening \(name) did not select a tab.")
      }
      try await waitForLivePage(id, expectedHost: fixture.host())
      try await waitForNonBlackCapture(id)
      opened.append(id)
      checks.append("\(name) renders live, non-black web contents")
    }

    guard let closing = opened.last else { throw Failure("Smoke tabs were not created.") }
    store.closeTab(closing)
    try await waitUntil("tab closure") { store.session.page(forTabID: closing) == nil }
    store.reopenLastClosedTab()
    guard let reopened = store.session.selectedSpace.selectedTabID,
      reopened != closing
    else { throw Failure("Closed tab did not reopen with a fresh identity.") }
    try await waitForLivePage(reopened, expectedHost: fixture.host())
    try await waitForNonBlackCapture(reopened)
    checks.append("closed tab reopens and renders live web contents")
    return checks
  }

  private func assertNoPicker(_ initialWindowCount: Int) throws {
    try expect(
      store.commandIsOpen && store.sheet == nil && NSApp.modalWindow == nil
        && NSApp.windows.count == initialWindowCount && NSApp.windows.allSatisfy { !$0.isVisible },
      "alphabet input opens no menu, picker, modal, or visible window")
  }

  private func waitForLivePage(_ id: UUID, expectedHost: String?) async throws {
    try await waitUntil("live page \(id)") {
      BasicBrowsingPageEvidence.isLive(
        await self.evaluate(id.uuidString), expectedHost: expectedHost)
    }
    let audit = runtime.normalProbeSelectionAudit(forTabID: id.uuidString)
    guard engine.pages[id] != nil, audit["liveTab"] as? Bool == true,
      audit["displayedNativeWebContents"] as? Bool == true
    else {
      throw Failure("Tab \(id) has no live native WebContents: \(audit)")
    }
  }

  private func waitForNonBlackCapture(_ id: UUID) async throws {
    try expect(
      NSApp.windows.allSatisfy { !$0.isVisible },
      "renderer capture starts with hidden windows")
    let data: Data? = await withCheckedContinuation { continuation in
      runtime.captureProbeTabID(id.uuidString) { continuation.resume(returning: $0) }
    }
    try expect(
      NSApp.windows.allSatisfy { !$0.isVisible },
      "renderer capture keeps windows hidden")
    guard let data, let bitmap = NSBitmapImageRep(data: data),
      bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0
    else { throw Failure("Live page \(id) produced no renderer capture.") }
    try expect(
      Self.containsNonBlackPixels(bitmap),
      "renderer capture for \(id) contains non-black page pixels")
  }

  static func containsNonBlackPixels(_ bitmap: NSBitmapImageRep) -> Bool {
    for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 12)) {
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 12)) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if color.redComponent > 0.03 || color.greenComponent > 0.03 || color.blueComponent > 0.03 {
          return true
        }
      }
    }
    return false
  }

  private func evaluate(_ id: String) async -> Any? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: id,
        script: "({href:location.href,ready:document.readyState,text:document.body?.innerText||''})"
      ) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func waitUntil(
    _ description: String, condition: @escaping () async -> Bool
  ) async throws {
    let timeout = 20.0 * ProbeTimeout.scale
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out waiting for \(description).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
