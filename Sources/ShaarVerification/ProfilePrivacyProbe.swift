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
    try expect(
      model.cookiesBlocked == nil,
      "the pinned engine reports third-party cookie policy as unavailable rather than inventing a preference"
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
      guard
        let directory = runtime.downloadsDirectory(forProfileID: profile.uuidString)?
          .deletingLastPathComponent(), directory.isFileURL,
        directory.lastPathComponent.lowercased() == "profile \(profile.uuidString.lowercased())",
        FileManager.default.fileExists(atPath: directory.path)
      else {
        throw ProfilePrivacyProbeFailure(
          message: "The disposable engine profile directory could not be verified.")
      }
      directories[profile] = directory
    }
    for profile in [first, second] {
      try await backend.deleteProfile(profile)
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
