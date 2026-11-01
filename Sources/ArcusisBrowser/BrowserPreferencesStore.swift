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
  private var connectedAccounts: [UUID: [ConnectedAccount]] = [:]
  private var pinnedExtensions: [UUID: [String]] = [:]
  private var autoPictureInPictureOffSites: [UUID: [String]] = [:]
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
      autoPictureInPictureOffSites = document.autoPictureInPictureOffSites
      developerSimulations = document.developerSimulations
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
        pinnedExtensions: pinnedExtensions, connectedAccounts: connectedAccounts,
        autoPictureInPictureOffSites: autoPictureInPictureOffSites,
        developerSimulations: developerSimulations)
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
  let autoPictureInPictureOffSites: [UUID: [String]]
  let developerSimulations: [UUID: [String: DeveloperSimulation]]

  private enum CodingKeys: String, CodingKey {
    case version
    case sidebarInitiallyVisible
    case profileSearchEngines
    case connectedAccounts
    case pinnedExtensions
    case autoPictureInPictureOffSites
    case developerSimulations
  }

  init(
    version: Int, sidebarInitiallyVisible: Bool,
    profileSearchEngines: [UUID: BrowserSearchEngine],
    pinnedExtensions: [UUID: [String]] = [:],
    connectedAccounts: [UUID: [ConnectedAccount]] = [:],
    autoPictureInPictureOffSites: [UUID: [String]] = [:],
    developerSimulations: [UUID: [String: DeveloperSimulation]] = [:]
  ) {
    self.version = version
    self.sidebarInitiallyVisible = sidebarInitiallyVisible
    self.profileSearchEngines = profileSearchEngines
    self.connectedAccounts = connectedAccounts
    self.pinnedExtensions = pinnedExtensions
    self.autoPictureInPictureOffSites = autoPictureInPictureOffSites
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
    developerSimulations =
      try values.decodeIfPresent(
        [UUID: [String: DeveloperSimulation]].self, forKey: .developerSimulations) ?? [:]
    autoPictureInPictureOffSites =
      try values.decodeIfPresent([UUID: [String]].self, forKey: .autoPictureInPictureOffSites)
      ?? [:]
  }
}
