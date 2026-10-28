import BrowserCore
import Darwin
import Foundation
import Observation

@MainActor @Observable
final class DownloadsFolderSource {
  private(set) var files: [URL] = []
  @ObservationIgnored private var identifiers: [URL: String] = [:]
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
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
        options: [.skipsHiddenFiles])) ?? []
    files = urls.filter { url in
      let ext = url.pathExtension.lowercased()
      guard ext != "crdownload", ext != "download",
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]),
        values.isRegularFile == true, values.isHidden != true
      else { return false }
      return true
    }
  }

  func items(profileID: UUID) -> [BrowserDownload] {
    files.compactMap { url in
      let key = url.standardizedFileURL.resolvingSymlinksInPath()
      let id = identifiers[key] ?? UUID().uuidString.lowercased()
      identifiers[key] = id
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      let size = Double(values?.fileSize ?? 0)
      return BrowserDownload(
        id: id, profileID: profileID, filename: url.lastPathComponent, path: url.path,
        sourceURL: "", state: .finished, paused: false, dangerous: false, offTheRecord: false,
        received: size, total: size,
        startTime: max(0, (values?.contentModificationDate ?? .distantPast).timeIntervalSince1970))
    }
  }
}
