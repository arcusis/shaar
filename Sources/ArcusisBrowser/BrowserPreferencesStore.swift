// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
  private var connectedAccounts: [UUID: [ConnectedAccount]] = [:]
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
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
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

  /// Google and Microsoft accounts signed in inside a profile, at most one per provider.
  func accounts(for profileID: UUID) -> [ConnectedAccount] {
    connectedAccounts[profileID] ?? []
  }

  func setAccount(_ account: ConnectedAccount, for profileID: UUID) {
    connectedAccounts[profileID] =
      accounts(for: profileID).filter { $0.provider != account.provider } + [account]
    save()
  }

  func removeAccount(_ provider: AccountProvider, for profileID: UUID) {
    let remaining = accounts(for: profileID).filter { $0.provider != provider }
    connectedAccounts[profileID] = remaining.isEmpty ? nil : remaining
    save()
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
      connectedAccounts = document.connectedAccounts
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
        profileSearchEngines: profileSearchEngines,
        pinnedExtensions: pinnedExtensions, connectedAccounts: connectedAccounts)
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
  let connectedAccounts: [UUID: [ConnectedAccount]]
  let pinnedExtensions: [UUID: [String]]

  private enum CodingKeys: String, CodingKey {
    case version
    case sidebarInitiallyVisible
    case profileSearchEngines
    case connectedAccounts
    case pinnedExtensions
  }

  init(
    version: Int, sidebarInitiallyVisible: Bool,
    profileSearchEngines: [UUID: BrowserSearchEngine],
    pinnedExtensions: [UUID: [String]] = [:],
    connectedAccounts: [UUID: [ConnectedAccount]] = [:]
  ) {
    self.version = version
    self.sidebarInitiallyVisible = sidebarInitiallyVisible
    self.profileSearchEngines = profileSearchEngines
    self.connectedAccounts = connectedAccounts
    self.pinnedExtensions = pinnedExtensions
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    sidebarInitiallyVisible = try values.decode(Bool.self, forKey: .sidebarInitiallyVisible)
    profileSearchEngines = try values.decode(
      [UUID: BrowserSearchEngine].self, forKey: .profileSearchEngines)
    connectedAccounts =
      try values.decodeIfPresent([UUID: [ConnectedAccount]].self, forKey: .connectedAccounts) ?? [:]
    pinnedExtensions =
      try values.decodeIfPresent([UUID: [String]].self, forKey: .pinnedExtensions) ?? [:]
  }
}
