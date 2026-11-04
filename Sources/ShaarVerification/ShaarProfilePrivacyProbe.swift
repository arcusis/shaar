// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

@testable import ArcusisBrowser

struct ShaarSiteDataSnapshot: Equatable, Sendable {
  let cookie: String?
  let storage: String?
}

/// The native probe host seeds and reads a hidden tab in each disposable profile.
protocol ShaarSiteDataPageFixture: Sendable {
  func seed(profileID: UUID, origin: String) async throws
  func snapshot(profileID: UUID, origin: String) async throws -> ShaarSiteDataSnapshot
}

/// Runs the same model used by Settings against the active Shaar site-data transport.
/// The caller owns two disposable profile IDs and the hidden page fixture.
@MainActor
final class ShaarProfilePrivacyProbe {
  let backend: any ProfileSettingsBackend
  let transport: any ShaarSiteDataTransport
  let fixture: any ShaarSiteDataPageFixture
  let first: UUID
  let second: UUID
  let origin: String

  init(
    backend: any ProfileSettingsBackend, transport: any ShaarSiteDataTransport,
    fixture: any ShaarSiteDataPageFixture, first: UUID, second: UUID, origin: String
  ) {
    self.backend = backend
    self.transport = transport
    self.fixture = fixture
    self.first = first
    self.second = second
    self.origin = origin
  }

  convenience init(
    engine: ShaarEngineTransport, profiles: ShaarProfileAdapter,
    fixture: any ShaarSiteDataPageFixture, first: UUID, second: UUID, origin: String
  ) throws {
    let transport = try ShaarSiteDataABITransport(resolver: engine, profileResolver: profiles)
    self.init(
      backend: ShaarProfileSettings(transport: transport, profiles: profiles),
      transport: transport, fixture: fixture, first: first, second: second, origin: origin)
  }

  func run() async throws -> [String] {
    try await backend.loadProfile(first)
    try await backend.loadProfile(second)
    let selected = adapter(for: first)
    let other = adapter(for: second)

    try await fixture.seed(profileID: first, origin: origin)
    try await fixture.seed(profileID: second, origin: origin)
    let beforeData = try await fixture.snapshot(profileID: second, origin: origin)
    try expect(
      beforeData.cookie != nil && beforeData.storage != nil,
      "Both disposable profiles have site data before clearing")

    let firstPolicy = try await selected.thirdPartyCookiePolicy()
    let secondPolicy = try await other.thirdPartyCookiePolicy()
    _ = try await selected.set(origin: origin, type: "camera", value: .allow)
    _ = try await other.set(origin: origin, type: "camera", value: .allow)
    let secondPermission = try await other.settings(origin: origin)["camera"]
    try expect(
      secondPermission == ShaarSiteSetting(value: .allow, isDefault: false),
      "Both disposable profiles have a saved camera exception")

    let model = ProfilePrivacyModel(profileID: first, backend: backend)
    await model.load()
    try expect(
      model.failure == nil && model.sites.contains { $0.id == origin },
      "Settings lists the selected profile's exception")

    await model.clear(siteData: true)
    let clearedData = try await fixture.snapshot(profileID: first, origin: origin)
    let retainedData = try await fixture.snapshot(profileID: second, origin: origin)
    try expect(
      model.failure == nil && clearedData.cookie == nil && clearedData.storage == nil
        && retainedData == beforeData,
      "Site-data clearing leaves the second profile untouched")

    await model.setCookiesBlocked(!firstPolicy.blocked)
    let changedPolicy = try await selected.thirdPartyCookiePolicy()
    let retainedPolicy = try await other.thirdPartyCookiePolicy()
    try expect(
      model.failure == nil && changedPolicy.blocked != firstPolicy.blocked
        && retainedPolicy == secondPolicy,
      "Third-party cookie policy changes only in the selected profile")

    await model.resetPermissions(origin: origin)
    let revoked = try await selected.settings(origin: origin)["camera"]
    let retainedPermission = try await other.settings(origin: origin)["camera"]
    try expect(
      model.failure == nil && revoked?.isDefault == true
        && retainedPermission == secondPermission,
      "Permission revocation leaves the second profile's exception untouched")

    return [
      "Site-data clearing leaves the second profile untouched",
      "Third-party cookie policy changes only in the selected profile",
      "Permission revocation leaves the second profile's exception untouched",
    ]
  }

  private func adapter(for id: UUID) -> ShaarSiteDataAdapter {
    ShaarSiteDataAdapter(profileID: id, implementation: .shaar, transport: transport)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ShaarProfilePrivacyProbeFailure(message: message) }
  }
}

private struct ShaarProfilePrivacyProbeFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
