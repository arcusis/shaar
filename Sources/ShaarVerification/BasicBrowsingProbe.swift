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

enum BasicBrowsingNavigationEvidence {
  static func searchDestination(
    _ destination: URL, matches engine: BrowserSearchEngine, query: String
  )
    -> Bool
  {
    guard let endpoint = URLComponents(string: engine.searchEndpoint.url),
      let actual = URLComponents(url: destination, resolvingAgainstBaseURL: false)
    else { return false }
    let queryItems = actual.queryItems ?? []
    return actual.scheme == endpoint.scheme && actual.host == endpoint.host
      && actual.path == endpoint.path && queryItems.count == 1
      && queryItems[0].name == engine.searchEndpoint.queryName
      && queryItems[0].value == query
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
    let searchEngine = store.preferences.searchEngine(for: store.session.selectedSpace.profileID)
    store.commandQuery = searchText
    guard
      let searchURL = NavigationInput.destination(
        for: searchText, searchEngine: searchEngine)
    else { throw Failure("Search query did not produce a destination.") }
    try expect(
      BasicBrowsingNavigationEvidence.searchDestination(
        searchURL, matches: searchEngine, query: searchText),
      "address bar search targets the selected default engine with the entered query")
    store.acceptCommand()
    guard let searchTab = store.session.selectedSpace.selectedTabID else {
      throw Failure("Search did not open a tab.")
    }
    guard store.session.selectedSpace.selectedTab?.url == searchURL else {
      throw Failure("Search command did not navigate to its selected result.")
    }
    try await waitForLivePage(searchTab, expectedHost: searchURL.host())
    checks.append("address bar search targets the selected default engine with the entered query")
    checks.append("normal window searches and lands on live results")

    let typedURL = fixture.appending(path: "typed-address-entry")
    store.showCommand()
    store.commandEditsCurrentURL = true
    store.commandQuery = typedURL.absoluteString
    guard NavigationInput.address(for: store.commandQuery) == typedURL else {
      throw Failure("The address bar did not parse the typed fixture URL as a web address.")
    }
    store.acceptCommand()
    guard let typedTab = store.session.selectedSpace.selectedTabID,
      store.session.selectedSpace.selectedTab?.url == typedURL
    else { throw Failure("Typing a web URL in the address bar did not navigate to it.") }
    try await waitForLivePage(typedTab, expectedHost: fixture.host())
    checks.append("address bar typed URL opens a live page")

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

    if let target = opened.first,
      let originalURL = store.session.page(forTabID: target)?.tab.url.absoluteString
    {
      checks += try await verifyPageInitiatedUnsafeNavigation(
        target, originalURL: originalURL)
    } else {
      throw Failure("Unsafe navigation fixture tab was not available.")
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

  private func verifyPageInitiatedUnsafeNavigation(_ id: UUID, originalURL: String) async throws
    -> [String]
  {
    let marker = "unsafe-navigation-\(UUID().uuidString.lowercased())"
    let blockedURLs = [
      "file:///etc/passwd", "chrome://version", "devtools://devtools/bundled/inspector.html",
      "javascript:document.documentElement.dataset['\(marker)']='ran'",
    ]
    let originalTabs = Set(store.session.spaces.flatMap(\.tabs).map(\.id))
    for address in blockedURLs {
      let encoded = try JSONEncoder().encode(address)
      guard let literal = String(data: encoded, encoding: .utf8) else {
        throw Failure("Could not encode an unsafe navigation URL.")
      }
      for initiation in ["location", "window.open", "link"] {
        let action: String
        switch initiation {
        case "location": action = "location.href=url"
        case "window.open": action = "window.open(url,'_blank')"
        default: action = "const a=document.createElement('a');a.href=url;a.click()"
        }
        _ = await evaluate(
          id.uuidString, "(()=>{const url=\(literal);\(action);return true})()")
        try await Task.sleep(for: .milliseconds(250))
        let state =
          await evaluate(
            id.uuidString,
            "({href:location.href,marker:document.documentElement.dataset['\(marker)']||''})")
          as? [String: Any]
        let tabs = Set(store.session.spaces.flatMap(\.tabs).map(\.id))
        try expect(
          state?["href"] as? String == originalURL
            && state?["marker"] as? String == ""
            && tabs == originalTabs,
          "page-initiated \(initiation) navigation to \(URLComponents(string: address)?.scheme ?? "unknown") is blocked"
        )
      }
    }
    return [
      "page-initiated location, window.open, and link attempts to four unsafe schemes are blocked"
    ]
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

  private func evaluate(
    _ id: String,
    _ script: String =
      "({href:location.href,ready:document.readyState,text:document.body?.innerText||''})"
  ) async -> Any? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: id, script: script) { continuation.resume(returning: $0) }
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
