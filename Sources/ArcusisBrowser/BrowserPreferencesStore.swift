// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class BrowserPreferencesStore {
  private static let maximumFileSize = 4 * 1024 * 1024

  private let fileURL: URL?
  private var profileSearchEngines: [UUID: BrowserSearchEngine] = [:]
  private var profileDownloadDirectories: [UUID: String] = [:]
  private var profileDownloadBookmarks: [UUID: Data] = [:]
  private var connectedAccounts: [UUID: [ConnectedAccount]] = [:]
  private var pinnedExtensions: [UUID: [String]] = [:]
  private var extensionDeveloperMode: [UUID: Bool] = [:]
  private var autoPictureInPictureOffSites: [UUID: [String]] = [:]
  private var profileHttpsOnlyMode: [UUID: Bool] = [:]
  private var developerSimulations: [UUID: [String: DeveloperSimulation]] = [:]
  private var preservesExistingFile = false

  private(set) var sidebarInitiallyVisible = true
  private(set) var storageNotice: String?

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    load()
  }

  func searchEngine(for profileID: UUID) -> BrowserSearchEngine {
    profileSearchEngines[profileID] ?? .google
  }

  func setSearchEngine(_ value: BrowserSearchEngine, for profileID: UUID) {
    profileSearchEngines[profileID] = value
    save()
  }

  /// Engine-acknowledged folder for this profile, with a bookmark for scoped access.
  func downloadDirectory(for profileID: UUID) -> URL? {
    if let bookmark = profileDownloadBookmarks[profileID] {
      var isStale = false
      if let url = try? URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      {
        return url.standardizedFileURL
      }
    }
    guard let path = profileDownloadDirectories[profileID] else { return nil }
    return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
  }

  func setDownloadDirectory(_ url: URL?, for profileID: UUID) {
    guard let url, url.isFileURL else {
      profileDownloadDirectories[profileID] = nil
      profileDownloadBookmarks[profileID] = nil
      save()
      return
    }
    let resolved = url.standardizedFileURL
    profileDownloadDirectories[profileID] = resolved.path
    profileDownloadBookmarks[profileID] = try? resolved.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    save()
  }

  /// Extensions pinned to the toolbar, in pin order, for one profile.
  func pinnedExtensionIDs(for profileID: UUID) -> [String] {
    pinnedExtensions[profileID] ?? []
  }

  func setExtension(_ id: String, pinned: Bool, for profileID: UUID) {
    var ids = pinnedExtensionIDs(for: profileID).filter { $0 != id }
    if pinned { ids.append(id) }
    pinnedExtensions[profileID] = ids.isEmpty ? nil : ids
    save()
  }

  /// Local Developer mode for unpacked extensions. The engine pref is separate and may refuse.
  func extensionDeveloperMode(for profileID: UUID) -> Bool {
    extensionDeveloperMode[profileID] == true
  }

  func setExtensionDeveloperMode(_ enabled: Bool, for profileID: UUID) {
    extensionDeveloperMode[profileID] = enabled ? true : nil
    save()
  }

  /// The Google or Microsoft account signed in inside a profile. Older preferences may list one
  /// account per provider; new connections keep at most one.
  func accounts(for profileID: UUID) -> [ConnectedAccount] {
    connectedAccounts[profileID] ?? []
  }

  /// Replaces any account the profile was connected to, whichever provider it came from.
  func setAccount(_ account: ConnectedAccount, for profileID: UUID) {
    connectedAccounts[profileID] = [account]
    save()
  }

  /// Onboarding must not report success until the connected account is on disk.
  func persistAccount(_ account: ConnectedAccount, for profileID: UUID) throws {
    let previous = connectedAccounts[profileID]
    connectedAccounts[profileID] = [account]
    save()
    guard storageNotice == nil else {
      connectedAccounts[profileID] = previous
      throw CocoaError(.fileWriteUnknown)
    }
  }

  func removeAccount(_ provider: AccountProvider, for profileID: UUID) {
    let remaining = accounts(for: profileID).filter { $0.provider != provider }
    connectedAccounts[profileID] = remaining.isEmpty ? nil : remaining
    save()
  }

  /// Automatic picture-in-picture is on unless the profile turned it off for the site.
  func allowsAutomaticPictureInPicture(on site: String, for profileID: UUID) -> Bool {
    !(autoPictureInPictureOffSites[profileID] ?? []).contains(site)
  }

  func setAutomaticPictureInPicture(_ allowed: Bool, on site: String, for profileID: UUID) {
    var sites = Set(autoPictureInPictureOffSites[profileID] ?? [])
    if allowed { sites.remove(site) } else { sites.insert(site) }
    autoPictureInPictureOffSites[profileID] = sites.isEmpty ? nil : sites.sorted()
    save()
  }

  /// Stored choice for a profile open. Nil when the preferences file could not be read,
  /// so an open must not invent on and overwrite a value already stored for the profile.
  /// A readable file with no entry for this profile is on.
  func httpsOnlyChoice(for profileID: UUID) -> Bool? {
    guard !preservesExistingFile else { return nil }
    return profileHttpsOnlyMode[profileID] ?? true
  }

  /// Switch value. An unreadable store shows on; that display is not a stored choice.
  func httpsOnlyModeEnabled(for profileID: UUID) -> Bool {
    httpsOnlyChoice(for: profileID) ?? true
  }

  func setHttpsOnlyMode(_ enabled: Bool, for profileID: UUID) {
    let stored = profileHttpsOnlyMode[profileID]
    if enabled {
      guard stored != nil else { return }
      profileHttpsOnlyMode[profileID] = nil
    } else {
      guard stored != false else { return }
      profileHttpsOnlyMode[profileID] = false
    }
    save()
  }

  func developerSimulation(on origin: String, for profileID: UUID) -> DeveloperSimulation {
    developerSimulations[profileID]?[origin] ?? DeveloperSimulation()
  }

  func setDeveloperSimulation(_ value: DeveloperSimulation, on origin: String, for profileID: UUID)
  {
    developerSimulations[profileID, default: [:]][origin] = value.isActive ? value : nil
    if developerSimulations[profileID]?.isEmpty == true { developerSimulations[profileID] = nil }
    save()
  }

  func setSidebarInitiallyVisible(_ value: Bool) {
    sidebarInitiallyVisible = value
    save()
  }

  /// Verifies preferences can be persisted before engine deletion becomes irreversible.
  func validateProfileRemoval() throws {
    guard !preservesExistingFile else { throw CocoaError(.fileWriteNoPermission) }
    // Refuse engine deletion when the existing preferences cannot be persisted.
    save()
    if storageNotice != nil { throw CocoaError(.fileWriteUnknown) }
  }

  /// Removes every app-owned preference for this identity, retaining other profiles and globals.
  func removeProfile(_ profileID: UUID) throws {
    try validateProfileRemoval()
    profileSearchEngines[profileID] = nil
    profileDownloadDirectories[profileID] = nil
    profileDownloadBookmarks[profileID] = nil
    connectedAccounts[profileID] = nil
    pinnedExtensions[profileID] = nil
    extensionDeveloperMode[profileID] = nil
    autoPictureInPictureOffSites[profileID] = nil
    profileHttpsOnlyMode[profileID] = nil
    developerSimulations[profileID] = nil
    save()
    if storageNotice != nil { throw CocoaError(.fileWriteUnknown) }
  }

  private func load() {
    guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }

    do {
      let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        preserveWithNotice(
          SettingsL10n.string("Saved preferences are not a regular file; original file preserved."))
        return
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      let handle = try FileHandle(forReadingFrom: fileURL)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
      guard data.count <= Self.maximumFileSize else {
        preserveWithNotice(
          SettingsL10n.string(
            "Saved preferences exceed the supported size; original file preserved."))
        return
      }
      let document = try JSONDecoder().decode(PreferencesDocument.self, from: data)
      guard document.version == 1 || document.version == 2 else {
        preserveWithNotice(
          SettingsL10n.string(
            "Saved preferences use an unsupported version; original file preserved."))
        return
      }
      sidebarInitiallyVisible = document.sidebarInitiallyVisible
      profileSearchEngines = document.profileSearchEngines
      profileDownloadDirectories = document.profileDownloadDirectories
      profileDownloadBookmarks = document.profileDownloadBookmarks
      connectedAccounts = document.connectedAccounts
      pinnedExtensions = document.pinnedExtensions
      extensionDeveloperMode = document.extensionDeveloperMode
      autoPictureInPictureOffSites = document.autoPictureInPictureOffSites
      profileHttpsOnlyMode = document.profileHttpsOnlyMode
      developerSimulations = document.developerSimulations
    } catch {
      preserveWithNotice(
        SettingsL10n.string("Saved preferences are invalid or unreadable; original file preserved.")
      )
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
        profileDownloadDirectories: profileDownloadDirectories,
        profileDownloadBookmarks: profileDownloadBookmarks,
        pinnedExtensions: pinnedExtensions, extensionDeveloperMode: extensionDeveloperMode,
        connectedAccounts: connectedAccounts,
        autoPictureInPictureOffSites: autoPictureInPictureOffSites,
        profileHttpsOnlyMode: profileHttpsOnlyMode,
        developerSimulations: developerSimulations)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(document)
      guard data.count <= Self.maximumFileSize else {
        storageNotice = SettingsL10n.string(
          "Preferences changed in memory but exceed the supported storage size.")
        return
      }
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      storageNotice = nil
    } catch {
      storageNotice = SettingsL10n.string(
        "Preferences changed in memory but could not be saved. Try again after fixing storage access."
      )
    }
  }
}

private struct PreferencesDocument: Codable {
  let version: Int
  let sidebarInitiallyVisible: Bool
  let profileSearchEngines: [UUID: BrowserSearchEngine]
  let profileDownloadDirectories: [UUID: String]
  let profileDownloadBookmarks: [UUID: Data]
  let connectedAccounts: [UUID: [ConnectedAccount]]
  let pinnedExtensions: [UUID: [String]]
  let extensionDeveloperMode: [UUID: Bool]
  let autoPictureInPictureOffSites: [UUID: [String]]
  let profileHttpsOnlyMode: [UUID: Bool]
  let developerSimulations: [UUID: [String: DeveloperSimulation]]

  private enum CodingKeys: String, CodingKey {
    case version
    case sidebarInitiallyVisible
    case profileSearchEngines
    case profileDownloadDirectories
    case profileDownloadBookmarks
    case connectedAccounts
    case pinnedExtensions
    case extensionDeveloperMode
    case autoPictureInPictureOffSites
    case profileHttpsOnlyMode
    case developerSimulations
  }

  init(
    version: Int, sidebarInitiallyVisible: Bool,
    profileSearchEngines: [UUID: BrowserSearchEngine],
    profileDownloadDirectories: [UUID: String] = [:],
    profileDownloadBookmarks: [UUID: Data] = [:],
    pinnedExtensions: [UUID: [String]] = [:],
    extensionDeveloperMode: [UUID: Bool] = [:],
    connectedAccounts: [UUID: [ConnectedAccount]] = [:],
    autoPictureInPictureOffSites: [UUID: [String]] = [:],
    profileHttpsOnlyMode: [UUID: Bool] = [:],
    developerSimulations: [UUID: [String: DeveloperSimulation]] = [:]
  ) {
    self.version = version
    self.sidebarInitiallyVisible = sidebarInitiallyVisible
    self.profileSearchEngines = profileSearchEngines
    self.profileDownloadDirectories = profileDownloadDirectories
    self.profileDownloadBookmarks = profileDownloadBookmarks
    self.connectedAccounts = connectedAccounts
    self.pinnedExtensions = pinnedExtensions
    self.extensionDeveloperMode = extensionDeveloperMode
    self.autoPictureInPictureOffSites = autoPictureInPictureOffSites
    self.profileHttpsOnlyMode = profileHttpsOnlyMode
    self.developerSimulations = developerSimulations
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
    extensionDeveloperMode =
      try values.decodeIfPresent([UUID: Bool].self, forKey: .extensionDeveloperMode) ?? [:]
    developerSimulations =
      try values.decodeIfPresent(
        [UUID: [String: DeveloperSimulation]].self, forKey: .developerSimulations) ?? [:]
    autoPictureInPictureOffSites =
      try values.decodeIfPresent([UUID: [String]].self, forKey: .autoPictureInPictureOffSites)
      ?? [:]
    profileHttpsOnlyMode =
      try values.decodeIfPresent([UUID: Bool].self, forKey: .profileHttpsOnlyMode) ?? [:]
    profileDownloadDirectories =
      try values.decodeIfPresent([UUID: String].self, forKey: .profileDownloadDirectories) ?? [:]
    profileDownloadBookmarks =
      try values.decodeIfPresent([UUID: Data].self, forKey: .profileDownloadBookmarks) ?? [:]
  }
}
