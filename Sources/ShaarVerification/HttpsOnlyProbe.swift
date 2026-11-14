// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

enum HttpsOnlyProbeEvidence {
  static let fixtureMarker = "plain-http-loaded"

  enum Verdict: Equatable {
    case waiting
    case unexpectedHttpPage
    case upgradeWarning
    case loadedHttpFixture
  }

  static func verdict(href: String, text: String, expectsUpgrade: Bool) -> Verdict {
    let loadedFixture = text.contains(fixtureMarker)
    let warned =
      text.range(of: "HTTPS", options: .caseInsensitive) != nil
      || text.range(of: "not secure", options: .caseInsensitive) != nil
    if expectsUpgrade {
      if loadedFixture { return .unexpectedHttpPage }
      if warned && !text.isEmpty { return .upgradeWarning }
    } else if loadedFixture && href.hasPrefix("http:") {
      return .loadedHttpFixture
    }
    return .waiting
  }
}

enum HttpsOnlyPageEvidence: Equatable {
  case retry
  case passed
  case failed(String)

  static func evaluate(
    href: String, text: String, expectsUpgrade: Bool, windowsHidden: Bool,
    fixtureMarker: String
  ) -> HttpsOnlyPageEvidence {
    let loadedFixture = text.contains(fixtureMarker)
    let warned =
      text.range(of: "HTTPS", options: .caseInsensitive) != nil
      || text.range(of: "not secure", options: .caseInsensitive) != nil
    if expectsUpgrade {
      if loadedFixture {
        return .failed("Public HTTP page loaded without an HTTPS-only warning.")
      }
      if warned && !text.isEmpty {
        return windowsHidden ? .passed : .failed("The HTTPS-only warning was visible on screen.")
      }
    } else if loadedFixture && href.hasPrefix("http:") {
      return windowsHidden ? .passed : .failed("The HTTP fixture was visible on screen.")
    }
    return .retry
  }
}

/// Hidden check that a public HTTP page on a non-default port shows the HTTPS-only interstitial.
@MainActor
final class HttpsOnlyProbe {
  static let fixtureMarker = HttpsOnlyProbeEvidence.fixtureMarker
  private static let pageScript =
    "({href:location.href,ready:document.readyState,text:(document.body&&document.body.innerText)||''})"

  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let tabID: UUID
  private let profileID: UUID
  private let output: URL
  private let dataRoot: URL
  private let pageURL: URL
  private let expectsUpgrade: Bool
  private var finished = false
  private var passed = false
  private var lastHref = ""
  private var lastText = ""
  private var reads = 0

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
        "The HTTPS-only probe requires Shaar Verification.app and its bundled Chromium framework. Build it with scripts/bundle-app.sh --with-engine --verification."
      )
    }
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    guard let url = URL(string: try value(after: "--probe-http-url")),
      url.scheme == "http", url.host == "trackertest.org", url.path == "/plain",
      let port = url.port, port != 80
    else {
      throw Failure("HTTPS-only probe requires http://trackertest.org:<port>/plain.")
    }
    pageURL = url
    expectsUpgrade = !arguments.contains("--probe-https-only-off")
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    let workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    store.perform(.open(pageURL))
    guard let id = store.session.selectedSpace.selectedTabID,
      let owner = store.session.profileID(forTabID: id)
    else { throw Failure("The fresh workspace did not create its first tab.") }
    tabID = id
    profileID = owner
    let preferences = BrowserPreferencesStore()
    if !expectsUpgrade { preferences.setHttpsOnlyMode(false, for: owner) }
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      preferences: preferences, presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let probe = try HttpsOnlyProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(Data("HTTPS-only probe: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    let previousCommitted = runtime.onDocumentCommitted
    runtime.onDocumentCommitted = { [weak self] id, profile in
      previousCommitted?(id, profile)
      guard let self, id == self.tabID.uuidString else { return }
      self.scheduleRead()
    }
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
        self.scheduleRead()
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
      self?.finish(error: "Timed out waiting for the HTTPS-only page.")
    }
    let result = runtime.run(
      withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func scheduleRead() {
    guard !finished else { return }
    reads += 1
    guard reads < 80 else {
      finish(error: "The page never produced an HTTPS-only verdict.")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.readPage()
    }
  }

  private func readPage() {
    guard !finished else { return }
    runtime.evaluate(inTabID: tabID.uuidString, script: Self.pageScript) { [weak self] json in
      DispatchQueue.main.async {
        self?.accept(json)
      }
    }
  }

  private func accept(_ json: String?) {
    guard !finished else { return }
    guard let json, let data = json.data(using: .utf8),
      let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      scheduleRead()
      return
    }
    let href = page["href"] as? String ?? ""
    let text = page["text"] as? String ?? ""
    lastHref = href
    lastText = text
    switch HttpsOnlyPageEvidence.evaluate(
      href: href, text: text, expectsUpgrade: expectsUpgrade, windowsHidden: windowsHidden,
      fixtureMarker: Self.fixtureMarker)
    {
    case .retry:
      scheduleRead()
    case .passed:
      finish(passed: true)
    case .failed(let message):
      finish(error: message)
    }
  }

  private var windowsHidden: Bool {
    NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private func seededValue() -> Any {
    let preferences = dataRoot.appending(path: "Chromium")
      .appending(path: "Profile \(profileID.uuidString.lowercased())")
      .appending(path: "Preferences")
    guard let data = try? Data(contentsOf: preferences),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "unreadable" }
    return json["https_only_mode_enabled"] ?? "missing"
  }

  private func finish(passed: Bool = false, error: String? = nil) {
    guard !finished else { return }
    finished = true
    let files = runtime.profileDirectoryEntriesBeforeOpen(forProfileID: profileID.uuidString)
    var message = error
    self.passed = passed && error == nil
    if self.passed && files != ["Preferences"] {
      self.passed = false
      let listed = files.isEmpty ? "nothing" : files.joined(separator: ", ")
      message = "First-open profile directory contained \(listed)."
    }
    let snippet = String(lastText.prefix(400))
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "https-only",
      "passed": self.passed,
      "expectsUpgrade": expectsUpgrade,
      "href": lastHref,
      "pageText": snippet,
      "seededHttpsOnly": seededValue(),
      "profileFilesBeforeOpen": files,
      "allWindowsHidden": windowsHidden,
      "requestedURL": pageURL.absoluteString,
      "error": message ?? "",
    ]
    do {
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      self.passed = false
      FileHandle.standardError.write(Data("HTTPS-only report failed: \(error)\n".utf8))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      for context in self.host.contexts.values {
        _ = self.runtime.closeWindowID(context.nativeID)
      }
      self.runtime.quit()
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
