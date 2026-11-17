// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Exercises profile-wide settings without touching the fixture's account profiles.
@MainActor
final class ProfilePrivacyProbe {
  let runtime: ARCChromiumRuntime
  let fixture: URL
  private var checks: [String] = []

  init(runtime: ARCChromiumRuntime, fixture: URL) {
    self.runtime = runtime
    self.fixture = fixture
  }

  func run() async throws -> [String] {
    let backend = EngineProfileSettings(runtime: runtime) { _ in nil }
    let first = UUID()
    let second = UUID()
    let firstTab = UUID()
    let secondTab = UUID()
    defer {
      runtime.discardTabID(firstTab.uuidString)
      runtime.discardTabID(secondTab.uuidString)
    }
    var address = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    address.host = "profile-privacy.localhost"
    address.path = "/profile-privacy"
    let url = address.url!
    let origin = SiteOrigin.string(for: url)!
    for (profile, tab) in [(first, firstTab), (second, secondTab)] {
      try await backend.loadProfile(profile)
      try runtime.openTabID(
        tab.uuidString, profileID: profile.uuidString, url: url.absoluteString)
      for _ in 0..<100 {
        if await evaluate(tab, "({ready:document.documentElement.dataset.arcusisFixture})")?[
          "ready"] as? String == "v1"
        {
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      try await seed(tab)
      try await runtime.setSiteSetting(
        "camera", value: "allow", origin: origin, profileID: profile.uuidString)
    }
    let model = ProfilePrivacyModel(profileID: first, backend: backend)
    await model.load()
    try expect(
      model.failure == nil && model.sites.contains { $0.id == origin },
      "Settings enumerates the selected profile's saved permission exceptions")
    // The pinned engine returns a real CookieControlsMode for a fresh profile:
    // third-party cookies blocked, and the pref is not enterprise-managed.
    // Nil is only for an engine that cannot read the pref at all.
    try expect(
      model.cookiesBlocked == true && model.cookiesManaged == false,
      "a fresh profile reports third-party cookies as blocked and not managed (blocked=\(String(describing: model.cookiesBlocked)) managed=\(model.cookiesManaged))"
    )
    await model.setCookiesBlocked(false)
    try expect(
      model.failure == nil && model.cookiesBlocked == false && model.cookiesManaged == false,
      "Settings allows third-party cookies on the selected profile (blocked=\(String(describing: model.cookiesBlocked)) managed=\(model.cookiesManaged) failure=\(model.failure ?? "nil"))"
    )
    await model.setCookiesBlocked(true)
    try expect(
      model.failure == nil && model.cookiesBlocked == true && model.cookiesManaged == false,
      "Settings restores the fresh profile's third-party cookie block (blocked=\(String(describing: model.cookiesBlocked)) managed=\(model.cookiesManaged) failure=\(model.failure ?? "nil"))"
    )
    await model.resetPermissions(origin: origin)
    let firstPermissions = try await backend.permissions(first, origin: origin)
    let secondPermissions = try await backend.permissions(second, origin: origin)
    try expect(
      model.failure == nil && firstPermissions["camera"]?["value"] as? String == "ask"
        && secondPermissions["camera"]?["value"] as? String == "allow",
      "Settings revokes a site's permissions in one profile while another profile retains its grant"
    )
    let path = "/profile-privacy-cache?probe=\(UUID().uuidString)"
    let firstCache = try await cacheToken(firstTab, path: path)
    let secondCache = try await cacheToken(secondTab, path: path)
    let cachedAgain = try await cacheToken(firstTab, path: path)
    try expect(
      cachedAgain == firstCache, "the authored cache resource is cached before Settings clears it")
    await model.clear(siteData: false)
    let clearedCache = try await cacheToken(firstTab, path: path)
    let retainedCache = try await cacheToken(secondTab, path: path)
    try expect(
      model.failure == nil && clearedCache != firstCache && retainedCache == secondCache,
      "Settings clears only the selected profile's HTTP cache")
    await model.clear(siteData: true)
    let firstData = await evaluate(
      firstTab, "({cookie:document.cookie,local:localStorage.getItem('siteControl')})")
    let secondData = await evaluate(
      secondTab, "({cookie:document.cookie,local:localStorage.getItem('siteControl')})")
    try expect(
      model.failure == nil && firstData?["cookie"] as? String == "" && firstData?["local"] is NSNull
        && secondData?["cookie"] as? String == "siteControl=kept"
        && secondData?["local"] as? String == "kept",
      "Settings clears only the selected profile's cookies and site storage")
    var directories: [UUID: URL] = [:]
    for profile in [first, second] {
      // Downloads default to the user Downloads folder. The engine profile
      // directory is the Chromium user-data folder named for this identity.
      let resolved = runtime.profileDataDirectory(forProfileID: profile.uuidString)
      guard
        let directory = resolved, directory.isFileURL,
        directory.lastPathComponent.lowercased() == "profile \(profile.uuidString.lowercased())",
        FileManager.default.fileExists(atPath: directory.path)
      else {
        throw ProfilePrivacyProbeFailure(
          message:
            "The disposable engine profile directory could not be verified (path=\(resolved?.path ?? "nil"))."
        )
      }
      directories[profile] = directory
    }
    for profile in [first, second] {
      // Delete refuses while this profile still owns a tab or its hidden
      // browser. Closing the tab lets Chromium drop that browser.
      let tab = profile == first ? firstTab : secondTab
      runtime.discardTabID(tab.uuidString)
      try await deleteWhenReleased(profile, backend: backend)
      let directory = directories[profile]!
      for _ in 0..<Int(300 * ProbeTimeout.scale) {
        if !FileManager.default.fileExists(atPath: directory.path) { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      try expect(
        !FileManager.default.fileExists(atPath: directory.path),
        "Chromium deletes the selected profile's engine directory, including its stored preferences and site data"
      )
      if profile == first {
        let retained = try await backend.permissions(second, origin: origin)
        try expect(
          FileManager.default.fileExists(atPath: directories[second]!.path)
            && retained["camera"]?["value"] as? String == "allow",
          "deleting one profile retains the other profile's engine directory and permissions")
      }
    }
    var retired = false
    do {
      _ = try await backend.permissionOrigins(first)
    } catch { retired = true }
    try expect(
      retired,
      "the bridge rejects services for the deleted engine profile's retired identity"
    )
    return checks
  }

  private func deleteWhenReleased(_ profile: UUID, backend: EngineProfileSettings) async throws {
    let retryable = "Close private windows before deleting this profile."
    var last = retryable
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      do {
        try await backend.deleteProfile(profile)
        return
      } catch {
        last = error.localizedDescription
        if last != retryable { throw error }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
    throw ProfilePrivacyProbeFailure(message: last)
  }

  private func cacheToken(_ tab: UUID, path: String) async throws -> String {
    let literal = String(
      data: try JSONSerialization.data(withJSONObject: path, options: [.fragmentsAllowed]),
      encoding: .utf8)!
    _ = await evaluate(
      tab,
      "(()=>{window.profileCacheToken=null;fetch(\(literal)).then(r=>r.text()).then(t=>window.profileCacheToken=t);return {started:true};})()"
    )
    for _ in 0..<100 {
      if let token = await evaluate(tab, "({token:window.profileCacheToken})")?["token"] as? String
      {
        return token
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProfilePrivacyProbeFailure(message: "The profile cache fixture did not finish.")
  }

  private func seed(_ tab: UUID) async throws {
    _ = await evaluate(
      tab,
      """
      (()=>{document.cookie='siteControl=kept; Path=/; Max-Age=600; SameSite=Lax';
        localStorage.setItem('siteControl','kept');return {seeded:true};})()
      """)
  }

  private func evaluate(_ tab: UUID, _ expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: expression) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ProfilePrivacyProbeFailure(message: message) }
    checks.append(message)
  }
}

private struct ProfilePrivacyProbeFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
