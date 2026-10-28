import BrowserCore
import CryptoKit
import Darwin
import Foundation
import Observation

/// Files in the Downloads folder, read once per folder change so Library lookups stay cheap.
@MainActor @Observable
final class DownloadsFolderSource {
  private(set) var files: [DownloadsFolderFile] = []
  @ObservationIgnored private var filesByID: [String: DownloadsFolderFile] = [:]
  @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
  private let directory: URL

  init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
  ) {
    self.directory = directory
    refresh()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      Task { @MainActor in self?.refresh() }
    }
    source.setCancelHandler { close(descriptor) }
    watcher = source
    source.resume()
  }

  deinit { watcher?.cancel() }

  func refresh() {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: DownloadsFolderFile.resourceKeys,
        options: [.skipsHiddenFiles])) ?? []
    files = urls.compactMap(DownloadsFolderFile.init(url:))
    filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  func item(id: String, profileID: UUID) -> BrowserDownload? {
    filesByID[id].flatMap { $0.download(profileID: profileID) }
  }

  func items(profileID: UUID) -> [BrowserDownload] {
    files.compactMap { $0.download(profileID: profileID) }
  }
}

struct DownloadsFolderFile: Equatable {
  static let resourceKeys: [URLResourceKey] = [
    .isRegularFileKey, .isHiddenKey, .fileSizeKey, .addedToDirectoryDateKey,
    .contentModificationDateKey,
  ]
  private static let partialExtensions: Set<String> = ["crdownload", "download", "part"]

  let url: URL
  /// Derived from the path, so an item keeps its id across refreshes.
  let id: String
  let size: Double
  let added: Date

  init?(url: URL) {
    guard !Self.partialExtensions.contains(url.pathExtension.lowercased()),
      let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)),
      values.isRegularFile == true, values.isHidden != true
    else { return nil }
    self.url = url.standardizedFileURL.resolvingSymlinksInPath()
    id = Self.stableID(path: self.url.path)
    size = Double(values.fileSize ?? 0)
    added = values.addedToDirectoryDate ?? values.contentModificationDate ?? .distantPast
  }

  private static func stableID(path: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return uuid.uuidString.lowercased()
  }

  func download(profileID: UUID) -> BrowserDownload? {
    BrowserDownload(
      id: id, profileID: profileID, filename: url.lastPathComponent,
      path: url.path, sourceURL: "", state: .finished, paused: false, dangerous: false,
      offTheRecord: false, received: size, total: size,
      startTime: max(0, added.timeIntervalSince1970))
  }
}
