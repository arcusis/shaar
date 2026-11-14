// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CoreFoundation
import Foundation

@testable import ArcusisBrowser

enum QuitExitProbeEvidence {
  static func backgroundModeIsOff(_ state: [String: Any]) -> Bool {
    guard let mode = state["background_mode"] as? [String: Any],
      let enabled = mode["enabled"] as? NSNumber,
      CFGetTypeID(enabled) == CFBooleanGetTypeID()
    else { return false }
    return !enabled.boolValue
  }
}

/// Quits through the production host's Quit menu command with an MV3 extension installed. The
/// parent fixture times main and helper process exit from the checkpoint written here; this
/// probe records Chromium's keep-alive registry until the engine loop ends. With a pending
/// navigation, every host window first starts loading a fixture page whose response never
/// arrives, so Quit tears the engine down while those navigations are in flight.
@MainActor
final class QuitExitProbe {
  static let mode = "quit-exit-only"
  static let scope =
    "Hidden host windows in disposable profiles with the component-loaded MV3 fixture. Quit is sent through the native menu command."
  static let pendingNavigationScope =
    "Hidden host windows in disposable profiles with the component-loaded MV3 fixture. Each phase seeds a fresh workspace; each window has a navigation in flight when Quit is sent through the native menu command."

  private let runtime: ARCChromiumRuntime
  private let primary: BrowserEngine
  private let store: BrowserStore
  private let root: URL
  private let fixture: URL
  private let phase: String
  let pendingNavigation: Bool
  private let lock: WorkspaceProcessLock
  private let file: WorkspaceFile
  private var host: NativeBrowserHost?
  private var sampler: Timer?
  private var checks: [String] = []
  private var sessionsBeforeQuit: [UUID: BrowserSession] = [:]

  init(
    runtime: ARCChromiumRuntime, primary: BrowserEngine, store: BrowserStore, root: URL,
    fixture: URL, phase: String, pendingNavigation: Bool
  ) throws {
    self.runtime = runtime
    self.primary = primary
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.pendingNavigation = pendingNavigation
    let directory = root.appending(
      path: pendingNavigation ? "quit-workspace-\(phase)" : "quit-workspace")
    lock = try WorkspaceProcessLock(directory: directory)
    file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
  }

  func run() async throws -> [String] {
    let profiles = store.session.profiles.map(\.id.uuidString)
    for profile in profiles { try await load(profile) }
    for profile in profiles {
      _ = try runtime.loadProbeExtension(at: root.appending(path: "Extension"), profileID: profile)
    }
    checks.append("every disposable profile loads the MV3 fixture")
    if phase == "initial" || pendingNavigation { try seedWorkspace() }
    let host = NativeBrowserHost(
      events: primary.events, workspace: try BrowserWorkspaceStore(file: file),
      presentation: .hiddenProbe, usesPrimaryWindow: false, keyWindow: { nil },
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1080)] })
    self.host = host
    try host.restore()
    try await waitForPages(in: host)
    checks.append("hidden host windows restore and load their pages before Quit")
    try expect(backgroundModeIsOff(), "Local State keeps Chromium background mode off")
    let state = runtime.probeKeepAliveState() ?? ""
    try expect(
      !state.contains("BACKGROUND_MODE_MANAGER"),
      "no background-mode keep-alive holds the browser before Quit")
    if pendingNavigation { try await startPendingNavigations(in: host) }
    record("before-quit")
    return checks
  }

  /// Sends Quit the way the menu does; the parent starts its exit deadline at this checkpoint.
  func requestQuit() throws {
    guard let host, let item = host.menuItem(for: .quit), let action = item.action,
      host.canPerform(.quit)
    else { throw QuitProbeFailure("The host has no enabled Quit menu command.") }
    sessionsBeforeQuit = Dictionary(
      uniqueKeysWithValues: host.workspace.workspace.windows.map { ($0.id, $0.session) })
    try writeCheckpoint()
    record("quit-requested")
    sampler = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      MainActor.assumeIsolated { self.record("quitting") }
    }
    // The item's own target and action, as a click delivers them. Chromium's application object
    // can drop an action sent through NSApp, so the runtime's state is the evidence Quit started.
    _ = (item.target as AnyObject?)?.perform(action, with: item)
    guard runtime.isQuitting else {
      throw QuitProbeFailure("The Quit menu command did not start quitting.")
    }
  }

  /// Whether the shutdown guard, not Chromium's own stop, ended the event loop.
  var stoppedEventLoop: Bool { runtime.probeQuitStoppedEventLoop }

  func auditAfterQuit() throws -> [String] {
    // The keep-alive registry is gone once the engine loop has ended; stop sampling it.
    sampler?.invalidate()
    sampler = nil
    guard let host else { throw QuitProbeFailure("Quit host is unavailable.") }
    let closed = host.contexts.isEmpty
    defer { host.detach() }
    guard closed else { throw QuitProbeFailure("Quit left a hidden host window open.") }
    try host.workspace.flushSaves()
    guard let saved = try file.load(), !sessionsBeforeQuit.isEmpty,
      Dictionary(uniqueKeysWithValues: saved.windows.map { ($0.id, $0.session) })
        == sessionsBeforeQuit
    else { throw QuitProbeFailure("Quit changed the saved windows or tab sessions.") }
    return [
      "Quit closes every hidden host window before the engine loop ends",
      "Quit retains every saved window and its ordinary tabs without archiving them",
    ]
  }

  private func expect(_ condition: Bool, _ name: String) throws {
    guard condition else { throw QuitProbeFailure(name) }
    checks.append(name)
  }

  private func backgroundModeIsOff() -> Bool {
    let url = root.appending(path: "Chromium/Local State")
    return Self.backgroundModeIsOff(try? Data(contentsOf: url))
  }

  static func backgroundModeIsOff(_ data: Data?) -> Bool {
    guard let data,
      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let mode = state["background_mode"] as? [String: Any]
    else { return false }
    guard let enabled = mode["enabled"] as? NSNumber,
      CFGetTypeID(enabled) == CFBooleanGetTypeID()
    else { return false }
    return !enabled.boolValue
  }

  private func load(_ profile: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      runtime.loadProfileID(profile) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  private func seedWorkspace() throws {
    let spaces = store.session.profiles.enumerated().map { index, profile in
      BrowserSpace(
        profileID: profile.id, name: "Quit \(index)", symbol: "house", tint: .lavender,
        tabs: [BrowserTab(url: fixture.appending(path: "quit-\(index)"))])
    }
    try SessionFile(url: file.legacySessionURL).save(
      BrowserSession(
        profiles: store.session.profiles, spaces: spaces, selectedSpaceID: spaces[0].id)
    )
  }

  private func waitForPages(in host: NativeBrowserHost) async throws {
    for _ in 0..<150 {
      let pages = host.contexts.values.flatMap { $0.engine.pages.values }
      if !host.contexts.isEmpty, !pages.isEmpty, pages.allSatisfy({ !$0.loading }) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw QuitProbeFailure("Hidden host pages did not finish loading.")
  }

  /// The fixture server holds `/stall` open, so these navigations stay pending through Quit.
  private func startPendingNavigations(in host: NativeBrowserHost) async throws {
    let stall = fixture.deletingLastPathComponent().appending(path: "stall")
    let engines = host.contexts.values.map(\.engine)
    for engine in engines {
      guard engine.navigateCurrentPage(to: stall) else {
        throw QuitProbeFailure("A host window could not start its pending navigation.")
      }
    }
    for _ in 0..<100 {
      if engines.allSatisfy({ $0.pages.values.contains(where: \.loading) }) {
        checks.append("every hidden host window has a navigation pending when Quit is sent")
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw QuitProbeFailure("Hidden host windows did not start their pending navigations.")
  }

  private func writeCheckpoint() throws {
    let checkpoint: [String: Any] = [
      "schema": 1, "phase": phase, "pid": Int(ProcessInfo.processInfo.processIdentifier),
    ]
    try JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys])
      .write(to: root.appending(path: "\(phase)-quit-requested.json"), options: .atomic)
  }

  /// Appends one line per sample so the parent can report what still held the process open.
  private func record(_ stage: String) {
    let state = runtime.probeKeepAliveState() ?? "unavailable"
    let line = "\(Date().timeIntervalSince1970) \(stage) quitting=\(runtime.isQuitting) \(state)\n"
    let url = root.appending(path: "\(phase)-quit-keepalive.log")
    guard let handle = try? FileHandle(forWritingTo: url) else {
      try? Data(line.utf8).write(to: url)
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}

private struct QuitProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
