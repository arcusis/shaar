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
  let folder: DownloadsFolderSource?

  init(folder: DownloadsFolderSource? = nil) { self.folder = folder }

  private(set) var notices: [UUID: String] = [:]
  @ObservationIgnored var onCommand:
    ((DownloadAction, String, UUID, @escaping @MainActor @Sendable (String?) -> Void) -> Void)?

  func items(in profileID: UUID) -> [BrowserDownload] {
    (records[profileID] ?? [:]).values.sorted {
      $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
    }
  }

  func libraryItems(in profileID: UUID) -> [BrowserDownload] {
    let browserItems = items(in: profileID)
    let paths = Set(
      browserItems.compactMap { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() })
    let generated = (generatedFiles[profileID] ?? [:]).keys.compactMap {
      generatedItem(id: $0, profileID: profileID)
    }
    let local = Dictionary(
      (generated + (folder?.items(profileID: profileID) ?? [])).map { ($0.id, $0) },
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
      ?? folder?.item(id: id, profileID: profileID)
  }

  func isFolderItem(_ item: BrowserDownload, profileID: UUID) -> Bool {
    records[profileID]?[item.id] == nil
      && (generatedItem(id: item.id, profileID: profileID) == item
        || folder?.item(id: item.id, profileID: profileID) == item)
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
    folder?.refresh()
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
      notices[profileID] = "Download controls are unavailable."
      return false
    }
    onCommand(action, id, profileID) { [weak self] error in self?.notices[profileID] = error }
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
    guard
      let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
      values.isRegularFile == true, values.isReadable == true,
      FileManager.default.isReadableFile(atPath: resolvedURL.path)
    else { return nil }
    return resolvedURL
  }

  func fileActionFailed(profileID: UUID) {
    notices[profileID] = "The downloaded file is no longer available."
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
