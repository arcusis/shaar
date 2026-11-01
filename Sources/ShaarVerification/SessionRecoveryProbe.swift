// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Initial phase: builds a managed workspace through the production writer, records the saved
/// snapshot, then keeps saving until the parent SIGKILLs this exact process. Restart phase:
/// restores the workspace in a fresh process and compares it with the recorded snapshot.
@MainActor
final class SessionRecoveryProbe {
  static let mode = "session-recovery-only"
  static let scope =
    "Owned managed workspace and authored loopback fixture. The parent sends SIGKILL to the exact probe PID during continuous saves; a fresh process restores and compares. No user profile, external host or power-loss simulation."
  static let readyName = "session-recovery-ready.json"
  static let expectedName = "session-recovery-expected.json"
  static let workspaceName = "session-recovery-workspace.json"
  private static let fixtureTitle = "Arcusis account isolation fixture"
  private static let churnGeometry = [
    WorkspaceWindowGeometry(x: 40, y: 40, width: 1000, height: 700),
    WorkspaceWindowGeometry(x: 80, y: 60, width: 1100, height: 760),
  ]

  let workspace: BrowserWorkspaceStore
  let store: BrowserStore
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let file: WorkspaceFile
  private var checks: [String] = []

  private init(
    workspace: BrowserWorkspaceStore, root: URL, fixture: URL, phase: String, file: WorkspaceFile,
    checks: [String]
  ) throws {
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw SessionRecoveryFailure("The workspace has no managed window.") }
    self.workspace = workspace
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.file = file
    self.checks = checks
  }

  static func open(root: URL, fixture: URL, phase: String) throws -> SessionRecoveryProbe {
    let file = WorkspaceFile(
      url: root.appending(path: workspaceName),
      legacySessionURL: root.appending(path: "session-recovery-unused-legacy.json"))
    let expected = root.appending(path: expectedName)
    if phase == "initial" {
      guard !FileManager.default.fileExists(atPath: file.url.path),
        !FileManager.default.fileExists(atPath: expected.path)
      else { throw SessionRecoveryFailure("Initial session-recovery artifacts already exist.") }
      let workspace = try BrowserWorkspaceStore(
        file: file, initialSession: authoredSession(fixture: fixture))
      return try SessionRecoveryProbe(
        workspace: workspace, root: root, fixture: fixture, phase: phase, file: file, checks: [])
    }
    let checks = try inspectFilesAfterKill(file)
    let workspace = try BrowserWorkspaceStore(file: file)
    guard workspace.storageNotice == nil else {
      throw SessionRecoveryFailure("The restored workspace reported a storage error.")
    }
    return try SessionRecoveryProbe(
      workspace: workspace, root: root, fixture: fixture, phase: phase, file: file,
      checks: checks + ["the restored workspace is writable without a storage notice"])
  }

  func run(runtime: ARCChromiumRuntime, engine: BrowserEngine) async throws -> [String] {
    if phase == "initial" {
      try await buildSessionAndAwaitKill(runtime: runtime, engine: engine)
    } else {
      try await verifyRestoredSession(runtime: runtime, engine: engine)
    }
    return checks
  }

  // MARK: Initial phase

  private static func authoredSession(fixture: URL) throws -> BrowserSession {
    let alphaProfile = BrowserProfile(name: "Recovery Alpha")
    let betaProfile = BrowserProfile(name: "Recovery Beta")
    let folder = BrowserFolder(name: "Recovery folder")
    let pinned = tab(fixture, "recovery-pinned", pinned: true, folderID: folder.id)
    let today = tab(fixture, "recovery-today")
    let alpha = BrowserSpace(
      profileID: alphaProfile.id, name: "Recovery alpha", symbol: "house", tint: .ocean,
      tabs: [pinned, today], folders: [folder])
    let beta = BrowserSpace(
      profileID: betaProfile.id, name: "Recovery beta", symbol: "briefcase", tint: .rose,
      tabs: [tab(fixture, "recovery-beta")])
    let shared = BrowserSpace(
      profileID: alphaProfile.id, name: "Recovery shared", symbol: "square.stack", tint: .forest,
      tabs: [tab(fixture, "recovery-shared")])
    var session = try BrowserSession(
      profiles: [alphaProfile, betaProfile], spaces: [alpha, beta, shared],
      selectedSpaceID: alpha.id)
    session.selectTab(today.id, in: alpha.id)
    guard
      session.addFavorite(
        profileID: alphaProfile.id, originalURL: fixture.appending(path: "recovery-favorite"),
        title: "Recovery favorite") != nil
    else { throw SessionRecoveryFailure("The authored favorite was rejected.") }
    return session
  }

  private static func tab(
    _ fixture: URL, _ path: String, pinned: Bool = false, folderID: UUID? = nil
  ) -> BrowserTab {
    BrowserTab(
      url: fixture.appending(path: path), title: fixtureTitle, isPinned: pinned,
      folderID: folderID)
  }

  private func buildSessionAndAwaitKill(runtime: ARCChromiumRuntime, engine: BrowserEngine)
    async throws
  {
    let alpha = store.session.spaces[0]
    let shared = store.session.spaces[2]
    guard let selected = alpha.selectedTabID, let folder = alpha.folders.first else {
      throw SessionRecoveryFailure("The authored session has no selected tab or folder.")
    }
    try await waitForDocument(selected, runtime: runtime, engine: engine)
    let navigated = fixture.appending(path: "recovery-navigated")
    try navigate(selected, to: navigated, runtime: runtime)
    try await waitFor("native navigation reaches the session model") {
      self.savedTab(selected, in: self.store.session)?.url == navigated
    }
    checks.append("native navigation updates the tab URL and title in the session model")

    store.perform(.open(fixture.appending(path: "recovery-opened")))
    store.perform(.tab(space: alpha.id, tab: selected))
    store.toggleFolder(folder.id, in: alpha.id)
    _ = store.updateSpace(shared.id, name: "Recovery shared renamed", tint: .lavender)
    store.cycleSpace(by: 1)
    store.cycleSpace(by: -1)
    let firstID = workspace.workspace.windows[0].id
    let secondID = try workspace.newWindow(from: firstID)
    try workspace.focusWindow(firstID)
    try workspace.setGeometry(Self.churnGeometry[0], for: secondID)
    try expectEqual(
      store.session.selectedSpace.selectedTabID, selected,
      "the navigated tab stays selected after tab, folder, Space and window changes")

    try await waitForSavedWorkspace(engine: engine)
    try SnapshotFile<BrowserWorkspace>(url: root.appending(path: Self.expectedName))
      .save(workspace.workspace)
    try writeReadyCheckpoint(
      chromiumVersion: runtime.chromiumVersion, churnWindowID: secondID, navigated: navigated)
    try await keepSavingUntilKilled(windowID: secondID)
  }

  /// Polls the primary file without flushing: background saves must land on their own.
  private func waitForSavedWorkspace(engine: BrowserEngine) async throws {
    var stablePolls = 0
    for _ in 0..<100 where stablePolls < 5 {
      try await Task.sleep(for: .milliseconds(100))
      let loading = engine.pages.values.contains { $0.loading }
      let saved = try? SnapshotFile<BrowserWorkspace>(url: file.url).loadPrimary()
      stablePolls = !loading && saved == workspace.workspace ? stablePolls + 1 : 0
    }
    guard stablePolls >= 5 else {
      throw SessionRecoveryFailure("Background saves did not reach the workspace file.")
    }
    checks.append("background saves reach the workspace file without an explicit flush")
    let backup = SnapshotFile<BrowserWorkspace>(url: file.url).backupURL
    try expect(
      FileManager.default.fileExists(atPath: backup.path),
      "a last-known-good backup exists beside the workspace file")
  }

  private func writeReadyCheckpoint(chromiumVersion: String, churnWindowID: UUID, navigated: URL)
    throws
  {
    let ready: [String: Any] = [
      "schema": 1, "ready": true, "phase": "initial", "mode": Self.mode,
      "pid": ProcessInfo.processInfo.processIdentifier,
      "expectedSnapshot": Self.expectedName, "workspaceFile": Self.workspaceName,
      "churnWindowID": churnWindowID.uuidString, "navigatedURL": navigated.absoluteString,
      "chromiumVersion": chromiumVersion, "checks": checks,
      "scope": "Saves continue after this checkpoint until the parent sends SIGKILL.",
    ]
    try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: Self.readyName), options: .atomic)
  }

  /// Alternates one window's geometry so the kill lands while snapshots are being written.
  private func keepSavingUntilKilled(windowID: UUID) async throws {
    var index = 1
    while true {
      try workspace.setGeometry(Self.churnGeometry[index % 2], for: windowID)
      index += 1
      try await Task.sleep(for: .milliseconds(4))
    }
  }

  // MARK: Restart phase

  private static func inspectFilesAfterKill(_ file: WorkspaceFile) throws -> [String] {
    let snapshot = SnapshotFile<BrowserWorkspace>(url: file.url)
    guard !FileManager.default.fileExists(atPath: snapshot.damagedURL.path) else {
      throw SessionRecoveryFailure("A damaged workspace file exists before restoration.")
    }
    guard (try? snapshot.loadPrimary()) != nil else {
      throw SessionRecoveryFailure("The primary workspace file is missing or torn after SIGKILL.")
    }
    return ["the primary workspace file is complete and valid after SIGKILL during saves"]
  }

  private func verifyRestoredSession(runtime: ARCChromiumRuntime, engine: BrowserEngine)
    async throws
  {
    let ready = try readyCheckpoint()
    guard
      let expected = try SnapshotFile<BrowserWorkspace>(
        url: root.appending(path: Self.expectedName)
      )
      .loadPrimary(),
      let churnID = UUID(uuidString: ready["churnWindowID"] as? String ?? ""),
      let navigated = URL(string: ready["navigatedURL"] as? String ?? "")
    else { throw SessionRecoveryFailure("The recorded recovery checkpoint is incomplete.") }
    let restored = workspace.workspace
    let churned = restored.window(churnID)?.geometry
    try expect(
      churned.map(Self.churnGeometry.contains) == true,
      "the window saved during the kill restores one of its written geometries")
    var normalized = restored
    try normalized.setGeometry(try require(expected.window(churnID)?.geometry), for: churnID)
    try expectEqual(
      normalized, expected,
      "Spaces, tabs, favorites, folders, selection and windows restore exactly after SIGKILL")

    let selected = try require(store.session.selectedSpace.selectedTabID)
    try expectEqual(
      savedTab(selected, in: store.session)?.url, navigated,
      "the selected tab restores the address it navigated to before the kill")
    try await waitForDocument(selected, runtime: runtime, engine: engine)
    let address = try await evaluate(selected, "location.href", runtime: runtime) as? String
    try expectEqual(
      address, navigated.absoluteString, "the engine reopens the restored tab at its saved address")

    try expect(workspace.persistSnapshot(), "the restored workspace saves again")
    try expect(
      try temporaryFiles().isEmpty, "temporary files left by the killed writer are removed")
  }

  private func readyCheckpoint() throws -> [String: Any] {
    let data = try Data(contentsOf: root.appending(path: Self.readyName))
    guard let ready = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      ready["mode"] as? String == Self.mode, ready["ready"] as? Bool == true
    else { throw SessionRecoveryFailure("The recovery ready checkpoint is invalid.") }
    return ready
  }

  private func temporaryFiles() throws -> [String] {
    let prefix = ".\(Self.workspaceName)."
    return try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
      $0.hasPrefix(prefix) && $0.hasSuffix(".tmp")
    }
  }

  // MARK: Helpers

  private func savedTab(_ id: UUID, in session: BrowserSession) -> BrowserTab? {
    session.spaces.flatMap(\.tabs).first { $0.id == id }
  }

  private func navigate(_ id: UUID, to url: URL, runtime: ARCChromiumRuntime) throws {
    let literal = String(decoding: try JSONEncoder().encode(url.absoluteString), as: UTF8.self)
    runtime.evaluate(
      inTabID: id.uuidString, script: "(()=>{location.href=\(literal);return {};})()"
    ) { _ in }
  }

  private func waitForDocument(_ id: UUID, runtime: ARCChromiumRuntime, engine: BrowserEngine)
    async throws
  {
    try await waitFor("the fixture document loads in \(id)") {
      runtime.nativeTabID(forID: id.uuidString) >= 0 && engine.pages[id]?.loading == false
    }
    for _ in 0..<100 {
      let marker = try? await evaluate(
        id, "document.documentElement.dataset.arcusisFixture", runtime: runtime)
      if marker as? String == "v1" { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw SessionRecoveryFailure("The fixture document did not load in \(id).")
  }

  private func evaluate(_ id: UUID, _ script: String, runtime: ARCChromiumRuntime) async throws
    -> Any
  {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: id.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let json, let data = json.data(using: .utf8) else {
      throw SessionRecoveryFailure("JavaScript evaluation failed for \(id).")
    }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func waitFor(_ name: String, _ condition: () -> Bool) async throws {
    for _ in 0..<(Int(200 * ProbeTimeout.scale)) {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw SessionRecoveryFailure("Timed out: \(name).")
  }

  private func expect(_ condition: Bool, _ name: String) throws {
    guard condition else { throw SessionRecoveryFailure(name) }
    checks.append(name)
  }

  private func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ name: String)
    throws
  {
    try expect(actual == expected, name)
  }
}

struct SessionRecoveryFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

private func require<Value>(_ value: Value?) throws -> Value {
  guard let value else { throw SessionRecoveryFailure("A recorded identity is missing.") }
  return value
}
