// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation

@testable import ArcusisBrowser

/// A component-loaded MV3 fixture proves API/profile boundaries, not store installation or Bitwarden.
@MainActor
final class ExtensionProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let phase: String
  private var checks: [String] = []
  private var popupWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    phase: String
  ) {
    self.runtime = runtime
    self.engine = engine
    self.store = store
    self.root = root
    self.phase = phase
  }

  func run() async throws -> [String] {
    let spaces = store.session.spaces
    let tabsBefore = spaces.flatMap { $0.tabs.map(\.id) }
    let profileA = spaces[0].profileID
    let profileB = spaces[1].profileID
    let fixtureURL = root.appending(path: "Extension")
    let extensionA = try runtime.loadProbeExtension(at: fixtureURL, profileID: profileA.uuidString)
    try await checkExtensionManager(profileA)
    store.perform(.space(spaces[0].id))
    engine.refreshExtensions()
    try expect(
      engine.extensions.contains { $0.id == extensionA }, "profile A lists its loaded MV3 fixture")
    store.perform(.space(spaces[1].id))
    engine.refreshExtensions()
    try expect(
      !engine.extensions.contains { $0.id == extensionA },
      "profile B does not list profile A's fixture")
    var foreignRejected = false
    do {
      try runtime.executeExtensionID(extensionA, tabID: spaces[1].selectedTabID!.uuidString)
    } catch { foreignRejected = true }
    try expect(foreignRejected, "profile B cannot execute an extension installed only in A")
    let extensionB = try runtime.loadProbeExtension(at: fixtureURL, profileID: profileB.uuidString)
    try expect(
      extensionA == extensionB, "the same extension ID has separate installations in two profiles")
    for space in spaces {
      runtime.reloadTabID(space.selectedTabID!.uuidString)
    }
    var oldPopupID: String?
    for (index, account) in [(0, "alpha"), (1, "beta"), (2, "alpha")] {
      let space = spaces[index]
      let tab = space.selectedTabID!.uuidString
      store.perform(.space(space.id))
      if let oldPopupID {
        try expect(
          runtime.view(forExtensionPopupID: oldPopupID) == nil,
          "switching spaces closes the previous profile's popup")
      }
      try await waitForContentScript(tab)
      engine.refreshExtensions()
      engine.executeExtension(extensionA)
      guard case .popup(let popup) = engine.extensionPanel else {
        throw ExtensionProbeFailure(
          "Native extension action did not produce a popup: \(engine.notice ?? "no notice")")
      }
      try expect(
        popup.profileID == space.profileID && popup.tabID == space.selectedTabID,
        "popup \(index) belongs to its selected space profile and tab")
      attachHiddenPopup(popup.id)
      let initial = try await waitForPopup(popup.id, expression: "window.probeState")
      try expect(
        initial["serviceWorker"] as? Bool == true,
        "popup \(index) connects to its MV3 service worker")
      try expect(
        (initial["tabID"] as? NSNumber)?.int32Value == runtime.nativeTabID(forID: tab),
        "popup \(index) targets the correct active tab through chrome.tabs")
      try expect(initial["error"] == nil, "popup \(index) reports no extension API error")
      if phase == "initial" && index < 2 {
        try expect(
          initial["account"] is NSNull, "profile \(index) starts with empty extension storage")
        _ = try await command(popup.id, message: ["action": "set", "account": account])
      } else {
        try expect(
          initial["account"] as? String == account,
          "\(phase) profile \(index) restores its own extension account")
      }
      let port = try await command(popup.id, message: ["action": "port"])
      try expect(
        port["port"] as? Bool == true && port["account"] as? String == account,
        "profile \(index) exchanges isolated state over a long-lived runtime port")
      let storage = try await command(popup.id, message: ["action": "storage-events"])
      try JSONSerialization.data(withJSONObject: storage, options: [.prettyPrinted, .sortedKeys])
        .write(
          to: root.appending(path: "\(phase)-extension-storage-\(index).json"), options: .atomic)
      try expect(storage["error"] == nil, "profile \(index) callback/event roundtrip completes")
      let own = storage["ownValue"] as? NSDictionary
      let worker = storage["workerValue"] as? NSDictionary
      try expect(
        own != nil && worker != nil && storage["callbackSet"] as? Bool == true
          && storage["workerCallback"] as? Bool == true
          && storage["callbackGet"] as? NSDictionary == own,
        "profile \(index) delivers storage callbacks and reads the serialized value")
      for (event, expected) in [
        ("areaOwn", own), ("areaWorker", worker), ("globalOwn", own), ("globalWorker", worker),
      ] {
        let change = storage[event] as? [String: Any]
        try expect(
          change?["newValue"] as? NSDictionary == expected && change?["oldValue"] == nil,
          "profile \(index) delivers \(event) storage notification with the original payload")
      }
      let cache = try await command(popup.id, message: ["action": "storage-cache-read"])
      try JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys])
        .write(
          to: root.appending(path: "\(phase)-extension-cache-read-\(index).json"), options: .atomic)
      try expect(
        cache["error"] == nil && cache["initial"] as? Bool == false
          && cache["refreshed"] as? Bool == true
          && cache["subsequentGuard"] as? Bool == true && cache["immediateGuard"] is Bool,
        "profile \(index) delivers the authored reactive-cache refresh without requiring event order"
      )
      let offscreen = try await command(popup.id, message: ["action": "offscreen"])
      try expect(
        (offscreen["offscreen"] as? [String: Any])?["document"] as? Bool == true,
        "profile \(index) can create and message an MV3 offscreen document")
      try expect(
        offscreen["account"] as? String == account,
        "profile \(index) keeps isolated chrome.storage.local data")
      let filled = try await command(popup.id, message: ["action": "fill"])
      try expect(filled["error"] == nil, "profile \(index) executes its scripting autofill fixture")
      let page = try await waitForPage(tab, account: account)
      try expect(
        page["username"] as? String == account
          && page["password"] as? String == "disposable-fixture-password",
        "profile \(index) fills only its selected local fixture tab")
      try expect(
        page["extensionAccount"] as? String == account,
        "profile \(index) content script receives its own storage changes")
      if index == 0 {
        let picture: Data? = await withCheckedContinuation { continuation in
          runtime.captureProbePopupID(popup.id) { continuation.resume(returning: $0) }
        }
        try expect(picture != nil, "engine captures the real MV3 popup in a hidden fixture window")
        try picture?.write(to: root.appending(path: "\(phase)-extension.png"), options: .atomic)
      }
      oldPopupID = popup.id
    }
    engine.extensionPanel = nil
    if let oldPopupID {
      try expect(
        runtime.view(forExtensionPopupID: oldPopupID) == nil,
        "dismissing the extension closes its native popup")
    }
    try expect(
      store.session.spaces.flatMap { $0.tabs.map(\.id) } == tabsBefore,
      "extension popups never become persisted browser tabs")
    return checks
  }

  private func attachHiddenPopup(_ id: String) {
    guard let page = runtime.view(forExtensionPopupID: id) else { return }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = page
    page.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
    popupWindow = window
  }

  private func evaluatePopup(_ id: String, expression: String) async -> Any? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(id, script: expression) { continuation.resume(returning: $0) }
    }
    return json.flatMap { $0.data(using: .utf8) }.flatMap {
      try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed)
    }
  }

  /// The bundled manager extension answers chrome.management without adding tabs or windows.
  private func checkExtensionManager(_ profile: UUID) async throws {
    let tabsBefore = store.session.spaces.flatMap { $0.tabs.map(\.id) }
    let nativeBefore = tabsBefore.map { runtime.nativeTabID(forID: $0.uuidString) }
    var listed = false
    if case .value(let data)? = await manage(profile, .list) {
      listed = (try? JSONDecoder().decode([ManagedExtension].self, from: data)) != nil
    }
    try expect(listed, "bundled extension manager lists the profile's extensions")
    let missing = await manage(
      profile, .setEnabled(id: String(repeating: "a", count: 32), enabled: false))
    guard case .failure(let message)? = missing else {
      throw ExtensionProbeFailure("Extension manager accepted an unknown extension.")
    }
    try expect(
      message.contains("Failed to find extension"),
      "extension manager reports unknown extensions instead of changing state")
    let invalid = await manage(profile, .setEnabled(id: "not-an-extension-id", enabled: true))
    try expect(invalid == nil, "the bridge refuses invalid extension IDs before running a script")
    let tabsAfter = store.session.spaces.flatMap { $0.tabs.map(\.id) }
    try expect(
      tabsAfter == tabsBefore
        && tabsAfter.map { runtime.nativeTabID(forID: $0.uuidString) } == nativeBefore,
      "hidden extension manager page adds no tabs to the session or native windows")
  }

  private func manage(
    _ profile: UUID, _ operation: ExtensionManagementOperation
  ) async -> ExtensionManagementResult? {
    await withCheckedContinuation { continuation in
      runtime.manageExtensions(operation, profileID: profile) {
        continuation.resume(returning: ExtensionManagementResult(json: $0))
      }
    }
  }

  private func waitForPopup(_ id: String, expression: String) async throws -> [String: Any] {
    for _ in 0..<50 {
      if let value = await evaluatePopup(id, expression: expression) as? [String: Any] {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ExtensionProbeFailure("MV3 popup did not answer: \(expression)")
  }

  private func command(_ id: String, message: [String: String]) async throws -> [String: Any] {
    let json = String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!
    _ = await evaluatePopup(
      id,
      expression: """
        (() => { window.probeReply = null;
          window.probeCommand(\(json)).then(value => window.probeReply = value)
            .catch(error => window.probeReply = {error:String(error)}); return true; })()
        """)
    return try await waitForPopup(id, expression: "window.probeReply")
  }

  private func page(_ tab: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tab,
        script: """
          ({fixture:document.documentElement.dataset.arcusisFixture,
            extensionAccount:document.documentElement.dataset.extensionAccount,
            username:document.querySelector('#username')?.value,
            password:document.querySelector('#password')?.value})
          """
      ) { continuation.resume(returning: $0) }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func waitForContentScript(_ tab: String) async throws {
    for _ in 0..<60 {
      if let value = await page(tab), value["extensionAccount"] as? String != nil { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ExtensionProbeFailure("MV3 content script did not load in \(tab).")
  }

  private func waitForPage(_ tab: String, account: String) async throws -> [String: Any] {
    for _ in 0..<60 {
      if let value = await page(tab), value["extensionAccount"] as? String == account,
        value["username"] as? String == account
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ExtensionProbeFailure("MV3 scripting did not fill its owning tab.")
  }

  private func expect(_ condition: Bool, _ name: String) throws {
    guard condition else { throw ExtensionProbeFailure(name) }
    checks.append(name)
  }
}

private struct ExtensionProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
