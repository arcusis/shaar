// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Observation

@MainActor
protocol ProfileSettingsBackend {
  func loadProfile(_ id: UUID) async throws
  func clearSiteData(_ id: UUID) async throws
  func clearCache(_ id: UUID) async throws
  func permissionOrigins(_ id: UUID) async throws -> [String]
  func permissions(_ id: UUID, origin: String) async throws -> [String: NSDictionary]
  func resetPermissions(_ id: UUID, origin: String) async throws
  func thirdPartyCookiesBlocked(_ id: UUID) -> Bool?
  func thirdPartyCookiesManaged(_ id: UUID) -> Bool
  func setThirdPartyCookiesBlocked(_ blocked: Bool, profileID: UUID) async throws
  func deleteProfile(_ id: UUID) async throws
}

extension ProfileSettingsBackend {
  func thirdPartyCookiesManaged(_ id: UUID) -> Bool { false }
}

extension ARCChromiumRuntime {
  /// Loads a profile after applying the stored HTTPS-only choice.
  /// Settings and the browsing engine share this path. Nil leaves a stored value unchanged.
  func loadProfileID(
    _ profileID: UUID, httpsOnly enabled: Bool?, completion: @escaping @Sendable (Error?) -> Void
  ) {
    if let enabled, let shaar = self as? ARCShaarRuntime {
      _ = shaar.setHttpsOnlyModeEnabled(enabled, forProfileID: profileID.uuidString)
    }
    loadProfileID(profileID.uuidString, completion: completion)
  }
}

@MainActor
struct EngineProfileSettings: ProfileSettingsBackend {
  let runtime: ARCChromiumRuntime
  let httpsOnlyMode: (UUID) -> Bool?

  func loadProfile(_ id: UUID) async throws {
    try await ProfileSettingsCallback.run { completion in
      runtime.loadProfileID(id, httpsOnly: httpsOnlyMode(id)) { error in
        if let error {
          completion(.failure(error))
        } else {
          completion(.success(()))
        }
      }
    }
    if let shaar = runtime as? ARCShaarRuntime {
      try await ProfileSettingsCallback.run { completion in
        shaar.refreshThirdPartyCookiePolicy(forProfileID: id.uuidString) {
          completion(.success(()))
        }
      }
    }
  }
  func clearSiteData(_ id: UUID) async throws {
    try await runtime.clearProfileSiteData(forProfileID: id.uuidString)
  }
  func clearCache(_ id: UUID) async throws {
    try await runtime.clearCache(forProfileID: id.uuidString)
  }
  func permissionOrigins(_ id: UUID) async throws -> [String] {
    try await runtime.sitePermissionOrigins(forProfileID: id.uuidString)
  }
  func permissions(_ id: UUID, origin: String) async throws -> [String: NSDictionary] {
    try await runtime.siteSettings(forOrigin: origin, profileID: id.uuidString)
      .mapValues { $0 as NSDictionary }
  }
  func resetPermissions(_ id: UUID, origin: String) async throws {
    try await runtime.resetSitePermissions(forOrigin: origin, profileID: id.uuidString)
  }
  func thirdPartyCookiesBlocked(_ id: UUID) -> Bool? {
    runtime.thirdPartyCookiesBlocked(forProfileID: id.uuidString)?.boolValue
  }
  func thirdPartyCookiesManaged(_ id: UUID) -> Bool {
    (runtime as? ARCShaarRuntime)?.thirdPartyCookiesManaged(forProfileID: id.uuidString)?.boolValue
      ?? false
  }
  func setThirdPartyCookiesBlocked(_ blocked: Bool, profileID: UUID) async throws {
    try await runtime.setThirdPartyCookiesBlocked(blocked, profileID: profileID.uuidString)
  }
  func deleteProfile(_ id: UUID) async throws {
    try await runtime.deleteEngineProfileID(id.uuidString)
  }
}

private enum ProfileSettingsCallback {
  typealias Completion = @Sendable (Result<Void, any Error>) -> Void
  typealias Start = @MainActor (@escaping Completion) -> Void

  @MainActor
  static func run(_ start: Start) async throws {
    let gate = ProfileSettingsContinuation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        guard !Task.isCancelled else {
          gate.resume(.failure(CancellationError()))
          return
        }
        start { gate.resume($0) }
      }
    } onCancel: {
      gate.resume(.failure(CancellationError()))
    }
  }
}

private final class ProfileSettingsContinuation: @unchecked Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<Void, any Error>)
    case finished(Result<Void, any Error>)
  }

  private let lock = NSLock()
  private var state = State.waiting

  func install(_ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    switch state {
    case .waiting:
      state = .installed(continuation)
      lock.unlock()
    case .installed:
      lock.unlock()
      preconditionFailure("A profile settings continuation can only be installed once.")
    case .finished(let result):
      lock.unlock()
      continuation.resume(with: result)
    }
  }

  func resume(_ result: Result<Void, any Error>) {
    lock.lock()
    let continuation: CheckedContinuation<Void, any Error>?
    switch state {
    case .waiting:
      state = .finished(result)
      continuation = nil
    case .installed(let installed):
      state = .finished(result)
      continuation = installed
    case .finished:
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(with: result)
  }
}

enum ProfilePermissionDataError: LocalizedError {
  case invalidException

  var errorDescription: String? { description(language: .currentLaunchLanguage) }

  func description(language: BrowserLanguage) -> String {
    BrowserLocalization.string(
      "The engine returned invalid site permission data.", table: "Settings", language: language)
  }
}

struct ProfileSitePermission: Identifiable, Equatable {
  let id: String
  let value: SitePermissionValue

  var title: String {
    if let permission = SitePermission(rawValue: id) { return permission.title }
    switch id {
    case "autoplay": return SettingsL10n.string("Autoplay")
    case "javascript": return "JavaScript"
    case "images": return SettingsL10n.string("Images")
    case "clipboard": return SettingsL10n.string("Clipboard")
    case "automaticDownloads": return SettingsL10n.string("Automatic Downloads")
    case "cookies": return SettingsL10n.string("Cookies")
    case "midi": return "MIDI"
    case "protocolHandlers": return SettingsL10n.string("Protocol Handlers")
    case "sensors": return SettingsL10n.string("Sensors")
    case "windowManagement": return SettingsL10n.string("Window Management")
    case "localFonts": return SettingsL10n.string("Local Fonts")
    case "idleDetection": return SettingsL10n.string("Idle Detection")
    case "storageAccess": return SettingsL10n.string("Storage Access")
    case "fileSystem": return SettingsL10n.string("File System")
    case "keyboardLock": return SettingsL10n.string("Keyboard Lock")
    case "pointerLock": return SettingsL10n.string("Pointer Lock")
    case "cameraPanTiltZoom": return SettingsL10n.string("Camera Pan, Tilt and Zoom")
    default: return id
    }
  }

  var valueLabel: String {
    switch value {
    case .allow: SettingsL10n.string("Allowed")
    case .block: SettingsL10n.string("Blocked")
    case .ask: SettingsL10n.string("Ask")
    }
  }

  static func exceptions(_ settings: [String: NSDictionary]) throws -> [Self] {
    try settings.sorted { $0.key < $1.key }.compactMap { name, entry in
      guard let isDefault = entry["isDefault"] as? Bool else {
        throw ProfilePermissionDataError.invalidException
      }
      if isDefault { return nil }
      guard let rawValue = entry["value"] as? String,
        let value = SitePermissionValue(rawValue: rawValue)
      else { throw ProfilePermissionDataError.invalidException }
      return Self(id: name, value: value)
    }
  }
}

struct ProfilePermissionSite: Identifiable, Equatable {
  let id: String
  let permissions: [ProfileSitePermission]
}

/// One immutable profile identity per pane prevents late completions crossing profile selection.
@MainActor @Observable
final class ProfilePrivacyModel {
  let profileID: UUID
  private let backend: any ProfileSettingsBackend
  private(set) var sites: [ProfilePermissionSite] = []
  private(set) var cookiesBlocked: Bool?
  private(set) var cookiesManaged = false
  private(set) var busy = false
  private(set) var busyMessage: String?
  private(set) var loaded = false
  private(set) var failure: String?
  private(set) var message: String?

  static func resetPermissionsMessage(
    origin: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Site permissions for %@ reset to defaults.", table: "Settings", language: language,
      arguments: [.string(origin)])
  }

  init(profileID: UUID, backend: any ProfileSettingsBackend) {
    self.profileID = profileID
    self.backend = backend
  }

  func load() async {
    await run(
      progressMessage: "Loading site permissions…",
      failureMessage: "Could not load profile privacy settings. Try again.") {
      try await self.backend.loadProfile(self.profileID)
      try Task.checkCancellation()
      self.cookiesBlocked = self.backend.thirdPartyCookiesBlocked(self.profileID)
      self.cookiesManaged = self.backend.thirdPartyCookiesManaged(self.profileID)
      try await self.refreshPermissions()
      try Task.checkCancellation()
      self.loaded = true
    }
  }

  func clear(siteData: Bool) async {
    await run(
      progressMessage: siteData ? "Clearing site data…" : "Clearing cache…",
      failureMessage: "Could not clear this profile's data. Try again.") {
      try await self.backend.loadProfile(self.profileID)
      try Task.checkCancellation()
      if siteData {
        try await self.backend.clearSiteData(self.profileID)
      } else {
        try await self.backend.clearCache(self.profileID)
      }
      try Task.checkCancellation()
      self.message = SettingsL10n.string(siteData ? "Site data cleared." : "Cache cleared.")
    }
  }

  func resetPermissions(origin: String) async {
    guard sites.contains(where: { $0.id == origin }) else { return }
    await run(
      progressMessage: "Resetting site permissions…",
      failureMessage: "Could not reset site permissions. Try again.") {
      try await self.backend.loadProfile(self.profileID)
      try Task.checkCancellation()
      try await self.backend.resetPermissions(self.profileID, origin: origin)
      try Task.checkCancellation()
      try await self.refreshPermissions()
      try Task.checkCancellation()
      self.message = Self.resetPermissionsMessage(origin: origin)
    }
  }

  func setCookiesBlocked(_ blocked: Bool) async {
    guard cookiesBlocked != nil, !cookiesManaged else { return }
    await run(
      progressMessage: "Updating third-party cookie setting…",
      failureMessage: "Could not update the third-party cookie setting. Try again.") {
      try await self.backend.setThirdPartyCookiesBlocked(blocked, profileID: self.profileID)
      try Task.checkCancellation()
      self.cookiesBlocked = self.backend.thirdPartyCookiesBlocked(self.profileID)
      self.cookiesManaged = self.backend.thirdPartyCookiesManaged(self.profileID)
      if self.cookiesBlocked != blocked {
        self.failure = SettingsL10n.string(
          "This engine cannot read or change the third-party cookie policy. Your cookie policy has not been changed."
        )
      }
    }
  }

  private func refreshPermissions() async throws {
    let origins = try await backend.permissionOrigins(profileID)
    try Task.checkCancellation()
    var result: [ProfilePermissionSite] = []
    for origin in Set(origins).sorted() {
      let settings = try await backend.permissions(profileID, origin: origin)
      try Task.checkCancellation()
      let permissions = try ProfileSitePermission.exceptions(settings)
      if !permissions.isEmpty { result.append(.init(id: origin, permissions: permissions)) }
    }
    sites = result
  }

  private func run(
    progressMessage: String, failureMessage: String? = nil, _ operation: () async throws -> Void
  ) async {
    guard !busy else { return }
    busy = true
    busyMessage = SettingsL10n.string(progressMessage)
    failure = nil
    message = nil
    defer {
      busy = false
      busyMessage = nil
    }
    do {
      try await operation()
      guard !Task.isCancelled else { return }
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      if error is ProfilePermissionDataError {
        failure = error.localizedDescription
      } else {
        failure = failureMessage.map(SettingsL10n.string) ?? error.localizedDescription
      }
    }
  }
}
