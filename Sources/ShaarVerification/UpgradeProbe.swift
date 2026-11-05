// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

/// Reads a v0.1.0 Ardia fixture with Shaar and the real keychain in a disposable account.
@MainActor
final class UpgradeProbe {
  private let runtime: ARCShaarRuntime
  private let root: URL
  private let dataRoot: URL
  private let output: URL
  private let fixture: URL
  private let session: BrowserSession
  private var checks: [String: Bool] = [:]
  private var finished = false
  private var finishError: String?

  private static let requiredChecks: Set<String> = [
    "tabsAndProfiles", "cookie_alpha", "cookie_beta", "bookmarks_alpha", "bookmarks_beta",
    "headless",
  ]

  private static let alpha = "C766672E-AB82-4F84-8ED3-2C6D75AEB1D1"
  private static let beta = "F29A09F3-FAF9-4938-A25B-260F67F42CC3"
  private static let alphaTab = "8EDD2777-1856-499D-A38F-702B0660CA59"
  private static let betaTab = "B30C0118-3DA8-47D2-B661-D3F0FE3E5F98"

  private init(arguments: [String]) throws {
    func value(_ flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }
    root = URL(filePath: try value("--probe-data-dir"), directoryHint: .isDirectory)
      .standardizedFileURL.resolvingSymlinksInPath()
    let requestedOutput = URL(filePath: try value("--probe-output")).standardizedFileURL
    output = requestedOutput.deletingLastPathComponent().resolvingSymlinksInPath()
      .appending(path: requestedOutput.lastPathComponent)
    fixture = URL(string: try value("--probe-url"))!
    let home = URL(filePath: try value("--probe-home"), directoryHint: .isDirectory)
      .standardizedFileURL.resolvingSymlinksInPath()
    dataRoot = URL.applicationSupportDirectory.appending(
      path: ProductIdentity.dataFolderName, directoryHint: .isDirectory
    )
    .standardizedFileURL.resolvingSymlinksInPath()
    guard
      root.lastPathComponent.hasPrefix("arcusis-engine-probe-"),
      try String(contentsOf: root.appending(path: ".arcusis-probe"), encoding: .utf8)
        == "arcusis-engine-probe-v1\n",
      home.deletingLastPathComponent() == root.deletingLastPathComponent(),
      ProcessInfo.processInfo.environment["HOME"] == home.path,
      ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == home.path,
      dataRoot.path.hasPrefix(home.path + "/"),
      output.deletingLastPathComponent() == root,
      fixture.scheme == "http", fixture.host() == "127.0.0.1", fixture.port != nil,
      let saved = try SessionFile(url: dataRoot.appending(path: "session.json")).load()
    else { throw Failure("Upgrade probe requires its marked temporary HOME and Ardia session.") }
    session = saved
    let framework = URL(filePath: try value("--probe-framework"))
    runtime = try ARCShaarRuntime(frameworkURL: framework)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      NSApplication.shared.setActivationPolicy(.prohibited)
      let windowGuard = try HiddenWindowOrderGuard.install()
      defer { windowGuard.restore() }
      return try UpgradeProbe(arguments: arguments).run()
    } catch {
      FileHandle.standardError.write(Data("Upgrade probe: \(error)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    runtime.onReady = { [weak self] in
      guard let self else { return }
      Task { await self.exercise() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
      self?.finish(error: "Shaar upgrade probe timed out.")
    }
    // This mode deliberately omits SHAAR_ENGINE_TESTING and its mock keychain.
    let code = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: false)
    return code == 0 && Self.reportPassed(checks: checks, error: finishError) ? 0 : 1
  }

  private func exercise() async {
    do {
      let profiles = Set(session.profiles.map { $0.id.uuidString })
      let tabs = Set(session.spaces.flatMap { $0.tabs.map { $0.id.uuidString } })
      try expect(
        profiles.contains(Self.alpha) && profiles.contains(Self.beta)
          && tabs.contains(Self.alphaTab) && tabs.contains(Self.betaTab),
        name: "tabsAndProfiles")
      try await inspectProfile(Self.alpha, tabID: Self.alphaTab, account: "alpha")
      try await inspectProfile(Self.beta, tabID: Self.betaTab, account: "beta")
      try expect(NSApp.windows.allSatisfy { !$0.isVisible }, name: "headless")
      finish(error: nil)
    } catch {
      finish(error: String(describing: error))
    }
  }

  private func inspectProfile(_ profileID: String, tabID: String, account: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      runtime.loadProfileID(profileID) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    try runtime.openTabID(
      tabID, profileID: profileID, windowID: runtime.primaryWindowID,
      url: fixture.absoluteString)
    guard
      runtime.beginDeveloperSession(
        forTabID: tabID, profileID: profileID, windowID: runtime.primaryWindowID)
    else { throw Failure("Could not inspect the upgraded page.") }
    defer {
      runtime.endDeveloperSession(
        forTabID: tabID, profileID: profileID, windowID: runtime.primaryWindowID)
    }
    try await waitForCookie(tabID: tabID, account: account)
    try expect(true, name: "cookie_\(account)")
    let bookmarkData = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      runtime.bookmarks(forProfileID: profileID) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let value {
          do {
            continuation.resume(returning: try JSONSerialization.data(withJSONObject: value))
          } catch { continuation.resume(throwing: error) }
        } else {
          continuation.resume(throwing: Failure("No bookmarks returned."))
        }
      }
    }
    let title = account == "alpha" ? "Alpha console" : "Beta console"
    let tree = try JSONSerialization.jsonObject(with: bookmarkData)
    try expect(Self.containsBookmarkTitle(title, in: tree), name: "bookmarks_\(account)")
  }

  private func waitForCookie(tabID: String, account: String) async throws {
    for _ in 0..<80 {
      let json = await withCheckedContinuation { continuation in
        runtime.evaluate(inTabID: tabID, script: "document.cookie") {
          continuation.resume(returning: $0)
        }
      }
      if let json, let data = json.data(using: .utf8),
        let cookie = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
          as? String,
        cookie.contains("account=\(account)")
      {
        return
      }
      try await Task.sleep(for: .milliseconds(150))
    }
    throw Failure("Shaar could not read the old encrypted cookie for \(account).")
  }

  static func containsBookmarkTitle(_ title: String, in value: Any) -> Bool {
    if let dictionary = value as? [AnyHashable: Any] {
      if dictionary["t"] as? String == title { return true }
      return dictionary.values.contains { containsBookmarkTitle(title, in: $0) }
    }
    if let dictionary = value as? [String: Any] {
      if dictionary["t"] as? String == title { return true }
      return dictionary.values.contains { containsBookmarkTitle(title, in: $0) }
    }
    if let array = value as? [Any] {
      return array.contains { containsBookmarkTitle(title, in: $0) }
    }
    return false
  }

  private func expect(_ condition: Bool, name: String) throws {
    checks[name] = condition
    if !condition { throw Failure(name) }
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    finishError = error
    let report: [String: Any] = [
      "passed": Self.reportPassed(checks: checks, error: error), "checks": checks,
      "error": error ?? "",
      "backend": "shaar", "realKeychain": true,
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      FileHandle.standardError.write(Data("Upgrade report write failed: \(error)\n".utf8))
    }
    runtime.quit()
  }

  private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  static func reportPassed(checks: [String: Bool], error: String?) -> Bool {
    error == nil && Set(checks.keys) == requiredChecks && checks.values.allSatisfy { $0 }
  }
}
