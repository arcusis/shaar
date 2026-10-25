import BrowserCore
import Foundation
import Observation

@MainActor @Observable
final class DownloadsModel {
  private(set) var records: [UUID: [String: BrowserDownload]] = [:]
  private(set) var notices: [UUID: String] = [:]
  @ObservationIgnored var onCommand:
    ((DownloadAction, String, UUID, @escaping @MainActor @Sendable (String?) -> Void) -> Void)?

  func items(in profileID: UUID) -> [BrowserDownload] {
    (records[profileID] ?? [:]).values.sorted {
      $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
    }
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
