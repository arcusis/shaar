// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

private func profileEventInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

public enum ShaarProfileError: Error, Equatable, Sendable {
  case invalidIdentifier
  case directoryMismatch
  case notOpen
  case alreadyOpen
  case staleHandle
  case native(ShaarStatusCode)
}

/// Operations exposed by the profile slice of the native ABI. The opaque token never
/// escapes this adapter and is never put in app models.
@MainActor public protocol ShaarProfileEngine: AnyObject {
  func openProfile(id: String, relativeDirectory: String) async throws -> UInt64
  func createProfile(id: String, displayName: String) async throws -> UInt64
  func closeProfile(_ handle: UInt64) throws
  func deleteProfile(_ handle: UInt64) async throws
  func activateProfile(_ handle: UInt64, inWindow window: UInt64) throws
  func getProfileState(_ handle: UInt64, key: String) throws -> Data
  func setProfileState(_ handle: UInt64, key: String, valueJSON: Data) throws
  func profilePath(_ handle: UInt64) throws -> Data
  func storageKeychainProfile(_ handle: UInt64) throws -> ShaarStorageKeychainNativeProfile
}

/// UUID to native handle registry used by the Shaar implementation choice. Shipping remains
/// on Shaar; callers construct this after the engine starts.
@MainActor public final class ShaarProfileAdapter: ShaarStorageKeychainProfileResolving {
  private let engine: any ShaarProfileEngine
  private let onProfileEvent: @MainActor (ShaarCopiedEvent) -> Void
  private var handles: [String: UInt64] = [:]
  private var pending: [String: Task<UInt64, Error>] = [:]

  public init(
    engine: any ShaarProfileEngine, implementation: ShaarEngineImplementation,
    onProfileEvent: @escaping @MainActor (ShaarCopiedEvent) -> Void = { _ in }
  ) {
    precondition(implementation == .shaar, "profile ABI is selected only for Shaar")
    self.engine = engine
    self.onProfileEvent = onProfileEvent
  }

  public var loadedProfileIDs: Set<String> { Set(handles.keys) }

  public func resolve(profileID: UUID) async throws -> ShaarStorageKeychainNativeProfile {
    let id = profileID.uuidString.lowercased()
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    return try engine.storageKeychainProfile(handle)
  }

  /// Receives events only after `ShaarEventDispatcher` copied all borrowed C bytes.
  /// The callback is the seam used by the existing BrowserRuntimeRouter facade.
  public func receive(_ event: ShaarCopiedEvent) {
    guard event.kind == 2,
      let profileID = String(data: event.profileID, encoding: .utf8),
      event.sessionID.isEmpty, event.windowID.isEmpty, event.tabID.isEmpty,
      let payload = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      profileEventInteger(payload["schemaVersion"]) == 1,
      let kind = payload["kind"] as? String
    else { return }
    if kind == "deleted" || kind == "closed" { handles.removeValue(forKey: profileID) }
    onProfileEvent(event)
  }

  public func open(profileID: String) async throws {
    let id = try Self.validateUUID(profileID)
    if handles[id] != nil { return }
    if let existing = pending[id] {
      let handle = try await existing.value
      guard handle != 0 else { throw ShaarProfileError.staleHandle }
      if handles[id] == nil { handles[id] = handle }
      return
    }
    let relative = "Profile \(id)"
    let request = Task { try await engine.openProfile(id: id, relativeDirectory: relative) }
    pending[id] = request
    let handle: UInt64
    do {
      handle = try await request.value
      pending.removeValue(forKey: id)
    } catch {
      pending.removeValue(forKey: id)
      throw error
    }
    guard handle != 0 else { throw ShaarProfileError.staleHandle }
    guard handles[id] == nil else {
      try? engine.closeProfile(handle)
      return
    }
    handles[id] = handle
  }

  public func create(profileID: String, displayName: String) async throws {
    let id = try Self.validateUUID(profileID)
    guard handles[id] == nil, pending[id] == nil else {
      throw ShaarProfileError.alreadyOpen
    }
    guard !displayName.isEmpty, displayName.utf8.count <= 256 else {
      throw ShaarProfileError.native(.invalidArgument)
    }
    let request = Task { try await engine.createProfile(id: id, displayName: displayName) }
    pending[id] = request
    let handle: UInt64
    do {
      handle = try await request.value
      pending.removeValue(forKey: id)
    } catch {
      pending.removeValue(forKey: id)
      throw error
    }
    guard handle != 0 else { throw ShaarProfileError.staleHandle }
    guard handles[id] == nil else {
      try? engine.closeProfile(handle)
      return
    }
    handles[id] = handle
  }

  public func close(profileID: String) throws {
    let id = try Self.validateUUID(profileID)
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    try engine.closeProfile(handle)
    handles.removeValue(forKey: id)
  }

  public func delete(profileID: String) async throws {
    let id = try Self.validateUUID(profileID)
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    try await engine.deleteProfile(handle)
    handles.removeValue(forKey: id)
  }

  public func activate(profileID: String, inWindow window: UInt64) throws {
    let id = try Self.validateUUID(profileID)
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    try engine.activateProfile(handle, inWindow: window)
  }

  public func state(profileID: String, key: String) throws -> Data {
    let id = try Self.validateUUID(profileID)
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    return try engine.getProfileState(handle, key: key)
  }

  public func setState(profileID: String, key: String, valueJSON: Data) throws {
    let id = try Self.validateUUID(profileID)
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    try engine.setProfileState(handle, key: key, valueJSON: valueJSON)
  }

  public func path(profileID: String) throws -> Data {
    let id = try Self.validateUUID(profileID)
    guard let handle = handles[id] else { throw ShaarProfileError.notOpen }
    return try engine.profilePath(handle)
  }

  private static func validateUUID(_ value: String) throws -> String {
    guard let uuid = UUID(uuidString: value) else { throw ShaarProfileError.invalidIdentifier }
    let canonical = uuid.uuidString.lowercased()
    guard value == canonical else { throw ShaarProfileError.invalidIdentifier }
    return canonical
  }
}
