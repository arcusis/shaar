// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Hidden proof that an idle background tab is discarded and stays in the window.
/// An engine that cannot discard fails the verdict.
@MainActor enum SleepingTabsProbe {
  private static let idleGap: TimeInterval = 3 * 60 * 60

  static func run(frameworkURL: URL, outputURL: URL) -> Int32 {
    let root = outputURL.deletingLastPathComponent().appending(path: "profile")
    let report = Report()
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
        Task { await exercise(host: host, runtime: runtime, outputURL: outputURL, report: report) }
      }
      return withExtendedLifetime(host) {
        let dataRoot = outputURL.deletingLastPathComponent().appending(path: "Chromium")
        let code = runtime.run(withDataDirectory: dataRoot, testing: true)
        host.detach()
        if report.passed && code == 0 { return 0 }
        return 1
      }
    } catch {
      write(["passed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }

  private static func exercise(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, outputURL: URL, report: Report
  ) async {
    var payload: [String: Any] = ["passed": false]
    defer {
      payload["allWindowsHidden"] = NSApp.windows.allSatisfy { !$0.isVisible }
      if payload["passed"] as? Bool == true && payload["allWindowsHidden"] as? Bool != true {
        payload["passed"] = false
        payload["error"] = "A window became visible"
      }
      report.passed = payload["passed"] as? Bool == true
      write(payload, to: outputURL)
      host.events.quit()
    }
    do {
      try host.restore()
      guard let context = host.contexts.values.first else { throw Failure("No hidden window") }
      context.engine.sleepingTabs.policy = {
        SleepingTabsPolicy(enabled: true, timeout: 2 * 60 * 60, neverSleepHosts: [])
      }
      let first = context.store.session.open(URL(string: "https://example.com")!)
      guard let first else { throw Failure("Could not open the first tab") }
      context.engine.reconcile()
      let firstLive = await wait { context.engine.liveTabs.contains(first) }
      guard firstLive else {
        throw Failure(
          "The first tab did not become live (live=\(context.engine.liveTabs.count))")
      }
      let opened = context.store.session.open(URL(string: "https://example.org")!)
      guard let opened else { throw Failure("Could not open a second tab") }
      context.engine.reconcile()
      let ready = await wait {
        context.engine.liveTabs.contains(opened) && context.engine.liveTabs.contains(first)
      }
      guard ready else {
        throw Failure(
          "The second tab did not become live (live=\(context.engine.liveTabs.count))")
      }
      let selected = context.store.session.selectedPage?.tab.id
      guard
        let background = context.store.session.spaces.flatMap(\.tabs).first(where: {
          $0.id != selected
        })?.id
      else { throw Failure("No background tab") }
      let capable: Bool = await withCheckedContinuation { continuation in
        runtime.probeTabLifecycle(forTabID: background.uuidString) { value in
          continuation.resume(returning: value)
        }
      }
      let backgroundCandidate = context.engine.sleepingCandidates(in: context.store).first {
        $0.id == background
      }
      let before = context.store.session.spaces.flatMap(\.tabs).map(\.id)
      let now = Date()
      context.engine.suspendInactiveTabs(now: now)
      context.engine.suspendInactiveTabs(now: now.addingTimeInterval(idleGap))
      let sleeping = await wait { context.store.sleepingTabIDs.contains(background) }
      let after = context.store.session.spaces.flatMap(\.tabs).map(\.id)
      let stillListed = after.contains(background)
      let stillLive = context.engine.liveTabs.contains(background)
      context.engine.wakeIfSleeping(background)
      let awake = await wait { !context.store.sleepingTabIDs.contains(background) }
      let awakeLive = context.engine.liveTabs.contains(background)
      let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
      let rendererFailures = context.store.rendererFailures.count
      let passed =
        capable && sleeping && stillListed && stillLive && awake && awakeLive
        && hidden && before.contains(background) && rendererFailures == 0
      payload = [
        "passed": passed,
        "capable": capable,
        "backgroundStillListed": stillListed,
        "backgroundStillLive": stillLive,
        "sleeping": sleeping,
        "awakeAfterWake": awake && awakeLive,
        "tabCount": after.count,
        "allWindowsHidden": hidden,
        "rendererFailures": rendererFailures,
        "schedulerCapability": capabilityName(context.engine.sleepingTabs.capability),
        "backgroundCandidateLive": backgroundCandidate?.isLive ?? false,
        "backgroundCandidateVisible": backgroundCandidate?.isVisible ?? false,
        "backgroundCandidatePinned": backgroundCandidate?.isPinned ?? false,
        "backgroundCandidateKeepAlive": backgroundCandidate?.keepAlive ?? false,
        "backgroundCandidatePrivateActive": backgroundCandidate?.isPrivateActive ?? false,
        "backgroundCandidatePlaying": backgroundCandidate?.isPlaying ?? false,
        "backgroundCandidateCapturing": backgroundCandidate?.isCapturing ?? false,
        "backgroundCandidateHasInspector": backgroundCandidate?.hasInspector ?? false,
        "backgroundCandidateHasDeveloperTools": backgroundCandidate?.hasDeveloperTools ?? false,
        "backgroundCandidateHasDeveloperModel": context.engine.developerModels[background] != nil,
        "backgroundCandidateHasDeveloperToolsView": runtime.devToolsView(
          forTabID: background.uuidString) != nil,
        "backgroundCandidateProfileIsDownloading": backgroundCandidate?.profileIsDownloading
          ?? false,
      ]
      if let error = probeFailure(
        capable: capable, sleeping: sleeping, awake: awake && awakeLive,
        stillListed: stillListed, stillLive: stillLive, hidden: hidden,
        wasOpen: before.contains(background), rendererFailures: rendererFailures)
      {
        payload["error"] = error
      }
    } catch {
      payload = ["passed": false, "error": error.localizedDescription]
    }
  }

  static func probeFailure(
    capable: Bool, sleeping: Bool, awake: Bool, stillListed: Bool, stillLive: Bool, hidden: Bool,
    wasOpen: Bool, rendererFailures: Int
  ) -> String? {
    if !capable { return "The engine cannot discard this tab" }
    if !sleeping { return "The background tab stayed awake" }
    if !awake { return "The background tab did not wake" }
    if !stillListed { return "The background tab left the window" }
    if !stillLive { return "The background tab is no longer live" }
    if !hidden { return "A window became visible" }
    if !wasOpen { return "The background tab was not open before sleep" }
    if rendererFailures != 0 { return "The renderer failed" }
    return nil
  }

  private static func capabilityName(_ capability: SleepingTabScheduler.Capability) -> String {
    switch capability {
    case .unknown: return "unknown"
    case .probing: return "probing"
    case .capable: return "capable"
    }
  }

  private static func wait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
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

  private final class Report {
    var passed = false
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
