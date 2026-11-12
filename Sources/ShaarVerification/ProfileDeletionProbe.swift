// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge

@testable import ArcusisBrowser

/// Exercises the production profile deletion path against disposable engine profiles.
@MainActor
final class ProfileDeletionProbe {
  private let host: NativeBrowserHost
  private let fixture: URL

  init(host: NativeBrowserHost, fixture: URL) {
    self.host = host
    self.fixture = fixture
  }

  func run() async throws -> [String] {
    guard let settings = host.settingsController?.state,
      let runtime = settings.runtime, let backend = settings.profileBackend
    else { throw ProfileDeletionFailure("Profile deletion services missing") }

    let deleting = try host.workspace.createProfile(name: "Disposable deletion probe")
    let survivor = UUID()
    let survivorProfile = BrowserProfile(id: survivor, name: "Deletion survivor")
    _ = try host.workspace.createProfile(survivorProfile)
    let deletingTab = UUID()
    let survivorTab = UUID()
    let deletingWindow = UUID().uuidString
    let survivorWindow = UUID().uuidString
    try runtime.createWindowID(deletingWindow)
    try runtime.createWindowID(survivorWindow)
    defer {
      runtime.discardTabID(deletingTab.uuidString)
      runtime.discardTabID(survivorTab.uuidString)
      _ = runtime.closeWindowID(deletingWindow)
      _ = runtime.closeWindowID(survivorWindow)
    }
    var page = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    page.path = "/profile-deletion"
    let url = page.url!
    let deletingCookie = "deleteProbe=target-\(UUID().uuidString)"
    let survivorCookie = "deleteProbe=survivor-\(UUID().uuidString)"
    try await seed(
      deleting, tab: deletingTab, cookie: deletingCookie, runtime: runtime, backend: backend,
      windowID: deletingWindow, url: url)
    try await seed(
      survivor, tab: survivorTab, cookie: survivorCookie, runtime: runtime, backend: backend,
      windowID: survivorWindow, url: url)
    guard let deletedDirectory = directory(deleting, runtime: runtime),
      let survivorDirectory = directory(survivor, runtime: runtime),
      FileManager.default.fileExists(atPath: deletedDirectory.path),
      FileManager.default.fileExists(atPath: survivorDirectory.path)
    else { throw ProfileDeletionFailure("Profile deletion probe directories missing") }
    runtime.discardTabID(deletingTab.uuidString)
    guard runtime.closeWindowID(deletingWindow) else {
      throw ProfileDeletionFailure("Deleted profile's probe window did not close")
    }
    for _ in 0..<Int(50 * ProbeTimeout.scale) {
      if runtime.window(forID: deletingWindow) == nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard runtime.window(forID: deletingWindow) == nil else {
      throw ProfileDeletionFailure("Deleted profile's native window remained open")
    }

    try await settings.deleteProfile(deleting, movingSpacesTo: nil)
    guard !host.workspace.workspace.catalog.profiles.contains(where: { $0.id == deleting }) else {
      throw ProfileDeletionFailure("Deleted profile remains in the workspace")
    }
    for _ in 0..<Int(300 * ProbeTimeout.scale) {
      if !FileManager.default.fileExists(atPath: deletedDirectory.path) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !FileManager.default.fileExists(atPath: deletedDirectory.path),
      FileManager.default.fileExists(atPath: survivorDirectory.path)
    else {
      throw ProfileDeletionFailure(
        "Profile deletion did not isolate profile directories "
          + "(deletedExists=\(FileManager.default.fileExists(atPath: deletedDirectory.path)), "
          + "survivorExists=\(FileManager.default.fileExists(atPath: survivorDirectory.path)), "
          + "deletedPath=\(deletedDirectory.path), survivorPath=\(survivorDirectory.path)).")
    }

    let deletedWorkspaceEntry = host.workspace.workspace.catalog.profiles.contains {
      $0.id == deleting
    }
    let survivorWorkspaceEntry = host.workspace.workspace.catalog.profiles.contains {
      $0.id == survivor
    }
    guard !deletedWorkspaceEntry, survivorWorkspaceEntry
    else {
      throw ProfileDeletionFailure(
        "Profile deletion did not preserve workspace ownership "
          + "(deletedWorkspaceEntry=\(deletedWorkspaceEntry), "
          + "survivorWorkspaceEntry=\(survivorWorkspaceEntry)).")
    }

    runtime.discardTabID(survivorTab.uuidString)
    _ = runtime.closeWindowID(survivorWindow)
    try await settings.deleteProfile(survivor, movingSpacesTo: nil)

    return [
      "Profile deletion removes its data directory and workspace entry",
      "The other profile retains its data directory and workspace entry",
    ]
  }

  private func seed(
    _ profile: UUID, tab: UUID, cookie: String, runtime: ARCChromiumRuntime,
    backend: any ProfileSettingsBackend, windowID: String, url: URL
  ) async throws {
    try await backend.loadProfile(profile)
    try runtime.openTabID(
      tab.uuidString, profileID: profile.uuidString, windowID: windowID, url: url.absoluteString)
    let literal = String(data: try JSONEncoder().encode(cookie), encoding: .utf8)!
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      if let result = await evaluate(
        tab, "(()=>{document.cookie=\(literal)+'; Path=/; Max-Age=600';return document.cookie})()",
        runtime: runtime),
        result.contains(cookie)
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProfileDeletionFailure("Profile deletion cookie fixture did not become ready")
  }

  private func directory(_ profile: UUID, runtime: ARCChromiumRuntime) -> URL? {
    runtime.profileDataDirectory(forProfileID: profile.uuidString)
  }

  private func evaluate(_ tab: UUID, _ script: String, runtime: ARCChromiumRuntime) async -> String?
  {
    await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
  }
}

private struct ProfileDeletionFailure: LocalizedError {
  let message: String

  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
