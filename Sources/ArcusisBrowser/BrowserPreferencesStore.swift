import BrowserCore
import Darwin
import Foundation
import Observation

@MainActor @Observable
public final class BrowserPreferencesStore {
  private static let maximumFileSize = 4 * 1024 * 1024

  private let fileURL: URL?
  private let syncDirectory: (URL) throws -> Void
  private var profileSearchEngines: [UUID: BrowserSearchEngine] = [:]
  private var nativeVaultProfiles: [UUID: NativeVaultProfilePreferences] = [:]
  private var pinnedExtensions: [UUID: [String]] = [:]
  private var preservesExistingFile = false

  public private(set) var sidebarInitiallyVisible = true
  public private(set) var storageNotice: String?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    self.syncDirectory = Self.syncDirectory
    load()
  }

  init(fileURL: URL?, syncDirectory: @escaping (URL) throws -> Void) {
    self.fileURL = fileURL
    self.syncDirectory = syncDirectory
    load()
  }

  private static func syncDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw DurableVaultSaveError.writeFailed }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw DurableVaultSaveError.writeFailed }
  }

  public func searchEngine(for profileID: UUID) -> BrowserSearchEngine {
    profileSearchEngines[profileID] ?? .google
  }

  public func setSearchEngine(_ value: BrowserSearchEngine, for profileID: UUID) {
    profileSearchEngines[profileID] = value
    save()
  }

  /// Extensions pinned to the toolbar, in pin order, for one profile.
  public func pinnedExtensionIDs(for profileID: UUID) -> [String] {
    pinnedExtensions[profileID] ?? []
  }

  public func setExtension(_ id: String, pinned: Bool, for profileID: UUID) {
    var ids = pinnedExtensionIDs(for: profileID).filter { $0 != id }
    if pinned { ids.append(id) }
    pinnedExtensions[profileID] = ids.isEmpty ? nil : ids
    save()
  }

  public func nativeVaultPreferences(for profileID: UUID) -> NativeVaultProfilePreferences {
    if let stored = nativeVaultProfiles[profileID] { return stored }
    let value = NativeVaultProfilePreferences()
    nativeVaultProfiles[profileID] = value
    save()
    return value
  }

  public func setNativeVaultEnabled(_ enabled: Bool, for profileID: UUID) {
    var value = nativeVaultPreferences(for: profileID)
    value.isEnabled = enabled
    nativeVaultProfiles[profileID] = value
    save()
  }

  public func setNativeVaultServer(
    _ server: BitwardenServerConfiguration, for profileID: UUID
  ) {
    var value = nativeVaultPreferences(for: profileID)
    guard value.server != server else { return }
    value.server = server
    value.vaultID = UUID()
    value.accountID = nil
    nativeVaultProfiles[profileID] = value
    save()
  }

  public func setNativeVaultAccountID(_ accountID: UUID?, for profileID: UUID) {
    var value = nativeVaultPreferences(for: profileID)
    value.accountID = accountID
    nativeVaultProfiles[profileID] = value
    save()
  }

  public enum DurableVaultSaveError: Error, Equatable {
    case unavailable
    case bindingChanged
    case writeFailed
  }

  /// Commits account ownership only after the complete preferences file is written.
  /// A thrown error may follow a file mutation; callers must keep recovery fail-closed.
  public func persistNativeVaultAccountID(
    _ accountID: UUID?, for profileID: UUID, expected: NativeVaultProfilePreferences
  ) throws {
    var updated = expected
    updated.accountID = accountID
    try persistNativeVaultPreferences(updated, for: profileID, expected: expected)
  }

  public func persistNativeVaultServer(
    _ server: BitwardenServerConfiguration, for profileID: UUID,
    expected: NativeVaultProfilePreferences
  ) throws {
    guard expected.server != server else { return }
    var updated = expected
    updated.server = server
    updated.vaultID = UUID()
    updated.accountID = nil
    try persistNativeVaultPreferences(updated, for: profileID, expected: expected)
  }

  private func persistNativeVaultPreferences(
    _ updated: NativeVaultProfilePreferences, for profileID: UUID,
    expected: NativeVaultProfilePreferences
  ) throws {
    guard let fileURL, !preservesExistingFile else { throw DurableVaultSaveError.unavailable }
    guard nativeVaultProfiles[profileID] == expected else {
      throw DurableVaultSaveError.bindingChanged
    }
    var profiles = nativeVaultProfiles
    profiles[profileID] = updated
    do {
      let parent = fileURL.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: parent.path) {
        try FileManager.default.createDirectory(
          at: parent, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      let document = PreferencesDocument(
        version: 2, sidebarInitiallyVisible: sidebarInitiallyVisible,
        profileSearchEngines: profileSearchEngines, nativeVaultProfiles: profiles)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(document)
      guard data.count <= Self.maximumFileSize else { throw DurableVaultSaveError.writeFailed }
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.synchronize()
      // Ordinary preference writes may have created any ancestor earlier in this
      // process. Flush every directory entry through the filesystem root.
      var directory = parent.standardizedFileURL
      while true {
        try syncDirectory(directory)
        let ancestor = directory.deletingLastPathComponent().standardizedFileURL
        if ancestor.path == directory.path { break }
        directory = ancestor
      }
      guard try Data(contentsOf: fileURL) == data else { throw DurableVaultSaveError.writeFailed }
      nativeVaultProfiles = profiles
      storageNotice = nil
    } catch {
      storageNotice = "Preferences could not be saved. Try again after fixing storage access."
      throw DurableVaultSaveError.writeFailed
    }
  }

  public func setSidebarInitiallyVisible(_ value: Bool) {
    sidebarInitiallyVisible = value
    save()
  }

  private func load() {
    guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }

    do {
      let handle = try FileHandle(forReadingFrom: fileURL)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
      guard data.count <= Self.maximumFileSize else {
        preserveWithNotice("Saved preferences exceed the supported size; original file preserved.")
        return
      }
      let document = try JSONDecoder().decode(PreferencesDocument.self, from: data)
      guard document.version == 1 || document.version == 2 else {
        preserveWithNotice("Saved preferences use an unsupported version; original file preserved.")
        return
      }
      sidebarInitiallyVisible = document.sidebarInitiallyVisible
      profileSearchEngines = document.profileSearchEngines
      nativeVaultProfiles = document.nativeVaultProfiles
      pinnedExtensions = document.pinnedExtensions
    } catch {
      preserveWithNotice("Saved preferences are invalid or unreadable; original file preserved.")
    }
  }

  private func preserveWithNotice(_ notice: String) {
    preservesExistingFile = true
    storageNotice = notice
  }

  private func save() {
    guard let fileURL else { return }
    guard !preservesExistingFile else { return }

    do {
      let parentURL = fileURL.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: parentURL.path) {
        try FileManager.default.createDirectory(
          at: parentURL, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      let document = PreferencesDocument(
        version: 2, sidebarInitiallyVisible: sidebarInitiallyVisible,
        profileSearchEngines: profileSearchEngines, nativeVaultProfiles: nativeVaultProfiles,
        pinnedExtensions: pinnedExtensions)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(document)
      guard data.count <= Self.maximumFileSize else {
        storageNotice = "Preferences changed in memory but exceed the supported storage size."
        return
      }
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      storageNotice = nil
    } catch {
      storageNotice =
        "Preferences changed in memory but could not be saved. Try again after fixing storage access."
    }
  }
}

private struct PreferencesDocument: Codable {
  let version: Int
  let sidebarInitiallyVisible: Bool
  let profileSearchEngines: [UUID: BrowserSearchEngine]
  let nativeVaultProfiles: [UUID: NativeVaultProfilePreferences]
  let pinnedExtensions: [UUID: [String]]

  private enum CodingKeys: String, CodingKey {
    case version
    case sidebarInitiallyVisible
    case profileSearchEngines
    case nativeVaultProfiles
    case pinnedExtensions
  }

  init(
    version: Int, sidebarInitiallyVisible: Bool,
    profileSearchEngines: [UUID: BrowserSearchEngine],
    nativeVaultProfiles: [UUID: NativeVaultProfilePreferences],
    pinnedExtensions: [UUID: [String]] = [:]
  ) {
    self.version = version
    self.sidebarInitiallyVisible = sidebarInitiallyVisible
    self.profileSearchEngines = profileSearchEngines
    self.nativeVaultProfiles = nativeVaultProfiles
    self.pinnedExtensions = pinnedExtensions
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    sidebarInitiallyVisible = try values.decode(Bool.self, forKey: .sidebarInitiallyVisible)
    profileSearchEngines = try values.decode(
      [UUID: BrowserSearchEngine].self, forKey: .profileSearchEngines)
    nativeVaultProfiles =
      try values.decodeIfPresent(
        [UUID: NativeVaultProfilePreferences].self, forKey: .nativeVaultProfiles) ?? [:]
    pinnedExtensions =
      try values.decodeIfPresent([UUID: [String]].self, forKey: .pinnedExtensions) ?? [:]
  }
}

public struct NativeVaultProfilePreferences: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var server: BitwardenServerConfiguration
  public var vaultID: UUID
  public var accountID: UUID?
  public let deviceID: UUID

  public init(
    isEnabled: Bool = false, server: BitwardenServerConfiguration = .init(region: .us),
    vaultID: UUID = UUID(), accountID: UUID? = nil, deviceID: UUID = UUID()
  ) {
    self.isEnabled = isEnabled
    self.server = server
    self.vaultID = vaultID
    self.accountID = accountID
    self.deviceID = deviceID
  }
}
