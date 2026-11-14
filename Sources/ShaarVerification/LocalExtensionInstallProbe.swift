// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

enum LocalExtensionInstallProbeEvidence {
  static let extensionName = "Shaar local MV3 install probe"

  static func hasContentScriptMarker(_ page: [String: Any]?) -> Bool {
    page?["marker"] as? String == "local-mv3-v1"
  }

  static func consentMatches(
    _ request: ExtensionInstallRequest, profileID: UUID, tabID: UUID, sourceURL: URL
  ) -> Bool {
    request.kind == .install && request.browserExtension.name == extensionName
      && request.profileID == profileID && request.tabID == tabID
      && request.sourceURL == sourceURL
  }
}

/// Installs an authored unpacked MV3 fixture through the product extension manager.
/// All browser windows remain hidden; the fixture lives only in the probe's temporary root.
@MainActor
final class LocalExtensionInstallProbe {
  private let runtime: ARCChromiumRuntime
  private let store: BrowserStore
  private let root: URL
  private let phase: String
  private var checks: [String] = []

  init(
    runtime: ARCChromiumRuntime, store: BrowserStore,
    root: URL, phase: String
  ) {
    self.runtime = runtime
    self.store = store
    self.root = root
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try write(
        ["passed": true, "checks": checks, "phase": phase],
        name: "local-extension-install.json")
      return checks
    } catch {
      try? write(
        ["passed": false, "checks": checks, "phase": phase,
         "error": error.localizedDescription],
        name: "local-extension-install.json")
      throw error
    }
  }

  private func exercise() async throws {
    let page = store.session.selectedPage
    guard let tabID = page?.tab.id, let sourceURL = page?.tab.url,
      sourceURL.host() == "127.0.0.1"
    else {
      throw LocalExtensionInstallProbeFailure(
        "Local MV3 probe needs its selected loopback tab.")
    }
    let profileID = store.session.selectedSpace.profileID
    let manager = ExtensionManagerModel.shared(
      runtime: runtime, preferences: store.preferences, profileID: profileID)
    let fixture = root.appending(path: "UnpackedMV3", directoryHint: .isDirectory)
    try createFixture(at: fixture)

    manager.setDeveloperMode(true)
    manager.loadUnpacked(at: fixture, tabID: tabID)

    var consent: ExtensionInstallRequest?
    for _ in 0..<160 {
      consent = store.installationRequests.first {
        $0.browserExtension.name == LocalExtensionInstallProbeEvidence.extensionName
      }
      if consent != nil { break }
      if let status = manager.status {
        throw LocalExtensionInstallProbeFailure("Local MV3 request failed: \(status)")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let consent,
      LocalExtensionInstallProbeEvidence.consentMatches(
        consent, profileID: profileID, tabID: tabID, sourceURL: sourceURL),
      consent.matches(store.session)
    else {
      throw LocalExtensionInstallProbeFailure(
        "Local MV3 consent was not bound to its source tab and profile.")
    }
    checks.append("unpacked MV3 install requests consent for its owning profile and loopback tab")
    store.resolveInstallation(consent.id, accepted: true)

    var installed: ManagedExtension?
    for attempt in 0..<160 {
      if attempt.isMultiple(of: 10) { manager.refresh() }
      installed = manager.extensions.first {
        $0.name == LocalExtensionInstallProbeEvidence.extensionName
      }
      if installed?.enabled == true { break }
      if let status = manager.status {
        throw LocalExtensionInstallProbeFailure("Local MV3 install failed: \(status)")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard let installed, installed.enabled, installed.version == "1.0" else {
      throw LocalExtensionInstallProbeFailure(
        "Accepted unpacked MV3 extension did not appear enabled in its profile.")
    }
    checks.append("accepted unpacked MV3 extension appears enabled in the product extension list")

    runtime.reloadTabID(tabID.uuidString)
    var pageEvidence: [String: Any]?
    for _ in 0..<100 {
      pageEvidence = await evaluate(
        tabID, "({marker:document.documentElement.dataset.shaarLocalExtension})")
      if LocalExtensionInstallProbeEvidence.hasContentScriptMarker(pageEvidence) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard LocalExtensionInstallProbeEvidence.hasContentScriptMarker(pageEvidence) else {
      throw LocalExtensionInstallProbeFailure(
        "Unpacked MV3 content script did not run on the owning loopback tab.")
    }
    checks.append("unpacked MV3 content script runs in the owning loopback page")

    guard NSApp.windows.allSatisfy({ !$0.isVisible }) else {
      throw LocalExtensionInstallProbeFailure("A window became visible during the local MV3 probe.")
    }
    checks.append("all application windows remain hidden during local MV3 installation")

    manager.remove(installed.id)
    for attempt in 0..<100 {
      if attempt.isMultiple(of: 10) { manager.refresh() }
      if !manager.extensions.contains(where: { $0.id == installed.id }) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !manager.extensions.contains(where: { $0.id == installed.id }) else {
      throw LocalExtensionInstallProbeFailure(
        "Disposable unpacked MV3 extension did not uninstall cleanly.")
    }
    checks.append("disposable unpacked MV3 extension is removed after the probe")
  }

  private func createFixture(at folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
      "manifest_version": 3,
      "name": LocalExtensionInstallProbeEvidence.extensionName,
      "version": "1.0",
      "host_permissions": ["http://127.0.0.1/*"],
      "content_scripts": [[
        "matches": ["http://127.0.0.1/*"], "js": ["content.js"],
      ]],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try manifestData.write(to: folder.appending(path: "manifest.json"), options: .atomic)
    try "document.documentElement.dataset.shaarLocalExtension = 'local-mv3-v1';\n"
      .write(to: folder.appending(path: "content.js"), atomically: true, encoding: .utf8)
  }

  private func evaluate(_ tabID: UUID, _ script: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tabID.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func write(_ value: [String: Any], name: String) throws {
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appending(path: "\(phase)-\(name)"), options: .atomic)
  }
}

private struct LocalExtensionInstallProbeFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
