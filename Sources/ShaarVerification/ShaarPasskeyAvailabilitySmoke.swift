// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Hidden shipping check that WebAuthn is present and the platform authenticator stays unavailable.
/// The page script reads `isUserVerifyingPlatformAuthenticatorAvailable` only.
@MainActor enum ShaarPasskeyAvailabilitySmoke {
  static func run(frameworkURL: URL, outputURL: URL, pageURL: URL?) -> Int32 {
    guard let pageURL, acceptsPageURL(pageURL) else { return 2 }
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
        Task {
          await exercise(host: host, runtime: runtime, pageURL: pageURL, outputURL: outputURL)
        }
      }
      return withExtendedLifetime(host) {
        let dataRoot = outputURL.deletingLastPathComponent().appending(path: "Chromium")
        let code = runtime.run(withDataDirectory: dataRoot, testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  static func acceptsPageURL(_ pageURL: URL) -> Bool {
    pageURL.scheme == "http" && pageURL.host == "127.0.0.1"
      && pageURL.user == nil && pageURL.password == nil
  }

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, pageURL: URL, outputURL: URL
  ) async {
    var report: [String: Any] = ["passed": false]
    defer {
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      report["allWindowsHidden"] = hidden
      if !hidden {
        report["passed"] = false
      }
      write(report, to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      context.store.perform(.open(pageURL))
      let ready = await wait {
        context.engine.siteControlTarget?.url == pageURL
          && context.engine.siteControlTarget.flatMap { context.engine.pages[$0.tabID] }?.loading
            == false
      }
      guard ready, let tab = context.engine.siteControlTarget?.tabID else {
        throw Failure("Passkey page did not load")
      }
      let state = await poll(runtime, tab: tab)
      let quiet = host.contexts.values.allSatisfy { $0.store.rendererFailures.isEmpty }
      report = availabilityReport(state: state, quiet: quiet)
    } catch {
      report["error"] = error.localizedDescription
    }
  }

  private static func poll(_ runtime: ARCChromiumRuntime, tab: UUID) async -> [String: Any] {
    var latest: [String: Any] = [:]
    for _ in 0..<80 {
      if let state = await readAvailability(runtime, tab: tab) {
        latest = state
        let passkey = state["passkey"] as? String ?? ""
        if passkey != "" && passkey != "pending" { return state }
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return latest
  }

  private static func readAvailability(_ runtime: ARCChromiumRuntime, tab: UUID) async -> [String:
    Any]?
  {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: availabilityScript) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func availabilityReport(state: [String: Any], quiet: Bool) -> [String: Any] {
    let passkey = state["passkey"] as? String ?? ""
    let publicKeyCredential = state["publicKeyCredential"] as? Bool ?? false
    let platformAuthenticator = state["platformAuthenticator"] as? Bool ?? false
    let conditionalMediation = state["conditionalMediation"] as? Bool ?? false
    let credentialsGet = state["credentialsGet"] as? Bool ?? false
    let secureContext = state["secureContext"] as? Bool ?? false
    let passed =
      quiet && passkey == "false" && publicKeyCredential && platformAuthenticator
      && credentialsGet && secureContext
    return [
      "passed": passed, "passkey": passkey, "publicKeyCredential": publicKeyCredential,
      "platformAuthenticator": platformAuthenticator, "conditionalMediation": conditionalMediation,
      "credentialsGet": credentialsGet, "secureContext": secureContext,
      "rendererQuiet": quiet,
    ]
  }

  private static func wait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private static func write(_ value: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  /// Starts the platform-authenticator query and returns the latest dataset value.
  /// `evaluate` does not await promises, so the caller polls until `passkey` leaves `pending`.
  private static let availabilityScript = """
    (() => {
      const root = document.documentElement;
      if (!root.dataset.passkey) {
        root.dataset.passkey = "pending";
        const credential = window.PublicKeyCredential;
        const available = credential && credential.isUserVerifyingPlatformAuthenticatorAvailable;
        if (typeof available !== "function") {
          root.dataset.passkey = "missing";
        } else {
          available.call(credential).then(
            (value) => { root.dataset.passkey = value ? "true" : "false"; },
            (error) => { root.dataset.passkey = "error:" + (error && error.name ? error.name : "failed"); }
          );
        }
      }
      const credential = window.PublicKeyCredential;
      return {
        passkey: root.dataset.passkey || "",
        publicKeyCredential: typeof credential === "function",
        platformAuthenticator: typeof credential?.isUserVerifyingPlatformAuthenticatorAvailable === "function",
        conditionalMediation: typeof credential?.isConditionalMediationAvailable === "function",
        credentialsGet: typeof navigator.credentials?.get === "function",
        secureContext: window.isSecureContext === true
      };
    })()
    """

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
