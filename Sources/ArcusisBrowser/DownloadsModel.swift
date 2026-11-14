// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class DownloadsModel {
  private(set) var records: [UUID: [String: BrowserDownload]] = [:]
  private var generatedFiles: [UUID: [String: DownloadsFolderFile]] = [:]
  private var profileFolders: [UUID: DownloadsFolderSource] = [:]
  let folder: DownloadsFolderSource?
  private let profileDirectory: ((UUID) -> URL?)?

  init(folder: DownloadsFolderSource? = nil) {
    self.folder = folder
    profileDirectory = nil
  }

  init(profileDirectory: @escaping (UUID) -> URL?) {
    folder = nil
    self.profileDirectory = profileDirectory
  }

  private(set) var notices: [UUID: String] = [:]
  @ObservationIgnored var onCommand:
    ((DownloadAction, String, UUID, @escaping @MainActor @Sendable (String?) -> Void) -> Void)?

  func items(in profileID: UUID) -> [BrowserDownload] {
    (records[profileID] ?? [:]).values.sorted {
      $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
    }
  }

  func hasActiveDownload(in profileID: UUID) -> Bool {
    (records[profileID] ?? [:]).values.contains { $0.state == .downloading }
  }

  func libraryItems(in profileID: UUID) -> [BrowserDownload] {
    let browserItems = (records[profileID] ?? [:]).values.filter { item in
      item.state != .finished || Self.isRegularFile(item.fileURL)
    }
    let paths = Set(
      browserItems.compactMap { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() })
    let generated = (generatedFiles[profileID] ?? [:]).keys.compactMap {
      generatedItem(id: $0, profileID: profileID)
    }
    let local = Dictionary(
      (generated + (folderSource(for: profileID)?.items(profileID: profileID) ?? [])).map {
        ($0.id, $0)
      },
      uniquingKeysWith: { first, _ in first })
    let folderItems = local.values.filter {
      guard let url = $0.fileURL else { return false }
      return !paths.contains(url.standardizedFileURL.resolvingSymlinksInPath())
    }
    return (browserItems + folderItems).sorted {
      $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
    }
  }

  func libraryItem(id: String, profileID: UUID) -> BrowserDownload? {
    records[profileID]?[id] ?? generatedItem(id: id, profileID: profileID)
      ?? folderSource(for: profileID)?.item(id: id, profileID: profileID)
  }

  func isFolderItem(_ item: BrowserDownload, profileID: UUID) -> Bool {
    records[profileID]?[item.id] == nil
      && (generatedItem(id: item.id, profileID: profileID) == item
        || folderSource(for: profileID)?.item(id: item.id, profileID: profileID) == item)
  }

  private func generatedItem(id: String, profileID: UUID) -> BrowserDownload? {
    guard let file = generatedFiles[profileID]?[id] else { return nil }
    var fresh = file.url
    fresh.removeAllCachedResourceValues()
    return DownloadsFolderFile(url: fresh)?.download(profileID: profileID)
  }

  func registerGeneratedFile(_ url: URL, profileID: UUID) {
    guard let file = DownloadsFolderFile(url: url) else { return }
    generatedFiles[profileID, default: [:]][file.id] = file
    folderSource(for: profileID)?.refresh()
  }

  private func folderSource(for profileID: UUID) -> DownloadsFolderSource? {
    if let folder { return folder }
    guard let directory = profileDirectory?(profileID) else { return nil }
    let standardizedDirectory = directory.standardizedFileURL
    if let source = profileFolders[profileID], source.directoryURL == standardizedDirectory {
      return source
    }
    let source = DownloadsFolderSource(directory: standardizedDirectory)
    profileFolders[profileID] = source
    return source
  }

  private static func isRegularFile(_ url: URL?) -> Bool {
    guard let url, url.isFileURL,
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    else { return false }
    return values.isRegularFile == true
  }

  func restore(_ rows: [[String: Any]], profileID: UUID) {
    let items = rows.compactMap { decode($0, profileID: profileID) }
    records[profileID] = items.reduce(into: [:]) { $0[$1.id] = $1 }
  }

  func changed(_ record: [String: Any], profileID: UUID) {
    guard let download = decode(record, profileID: profileID) else { return }
    records[profileID, default: [:]][download.id] = download
  }

  func removed(_ id: String, profileID: UUID) {
    records[profileID]?[id] = nil
  }

  @discardableResult
  func perform(_ action: DownloadAction, id: String, profileID: UUID, selectedProfileID: UUID)
    -> Bool
  {
    guard selectedProfileID == profileID, let item = records[profileID]?[id],
      item.actions.contains(action)
    else { return false }
    notices[profileID] = nil
    guard let onCommand else {
      notices[profileID] = PanelsL10n.string("Download controls are unavailable.")
      return false
    }
    onCommand(action, id, profileID) { [weak self] error in
      guard let self, self.records[profileID]?[id]?.actions.contains(action) == true else { return }
      self.notices[profileID] = error
    }
    return true
  }

  func fileToOpen(id: String, profileID: UUID, selectedProfileID: UUID) -> URL? {
    guard selectedProfileID == profileID, let item = records[profileID]?[id], item.canOpen else {
      return nil
    }
    return item.fileURL
  }

  func fileForDrag(id: String, profileID: UUID, selectedProfileID: UUID) -> URL? {
    guard selectedProfileID == profileID, let item = libraryItem(id: id, profileID: profileID),
      item.profileID == profileID, item.canOpen, let url = item.fileURL
    else { return nil }
    let resolvedURL = url.resolvingSymlinksInPath()
    if records[profileID]?[id] != nil {
      guard let directory = folder?.directoryURL ?? profileDirectory?(profileID),
        Self.isContained(resolvedURL, in: directory)
      else { return nil }
    }
    guard
      let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
      values.isRegularFile == true, values.isReadable == true,
      FileManager.default.isReadableFile(atPath: resolvedURL.path)
    else { return nil }
    return resolvedURL
  }

  private static func isContained(_ file: URL, in directory: URL) -> Bool {
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let path = file.standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path != root && path.hasPrefix(prefix)
  }

  func fileActionFailed(profileID: UUID) {
    notices[profileID] = PanelsL10n.string("The downloaded file is no longer available.")
  }

  private func decode(_ record: [String: Any], profileID: UUID) -> BrowserDownload? {
    guard let id = record["id"] as? String, let filename = record["filename"] as? String,
      let path = record["path"] as? String, let address = record["url"] as? String,
      let state = (record["state"] as? String).flatMap(DownloadState.init(rawValue:)),
      let paused = record["paused"] as? Bool, let dangerous = record["dangerous"] as? Bool,
      let privateItem = record["offTheRecord"] as? Bool,
      let received = record["received"] as? Double, let total = record["total"] as? Double,
      let start = record["startTime"] as? Double
    else { return nil }
    return BrowserDownload(
      id: id, profileID: profileID, filename: filename, path: path, sourceURL: address,
      state: state, paused: paused, dangerous: dangerous, offTheRecord: privateItem,
      received: received, total: total, startTime: start)
  }
}
