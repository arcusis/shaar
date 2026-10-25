import BrowserCore
import Foundation
import Observation

@MainActor @Observable
public final class BrowserPreferencesStore {
  private static let maximumFileSize = 4 * 1024 * 1024

  private let fileURL: URL?
  private var profileSearchEngines: [UUID: BrowserSearchEngine] = [:]
  private var preservesExistingFile = false

  public private(set) var sidebarInitiallyVisible = true
  public private(set) var storageNotice: String?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    load()
  }

  public func searchEngine(for profileID: UUID) -> BrowserSearchEngine {
    profileSearchEngines[profileID] ?? .google
  }

  public func setSearchEngine(_ value: BrowserSearchEngine, for profileID: UUID) {
    profileSearchEngines[profileID] = value
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
      guard document.version == 1 else {
        preserveWithNotice("Saved preferences use an unsupported version; original file preserved.")
        return
      }
      sidebarInitiallyVisible = document.sidebarInitiallyVisible
      profileSearchEngines = document.profileSearchEngines
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
        version: 1, sidebarInitiallyVisible: sidebarInitiallyVisible,
        profileSearchEngines: profileSearchEngines)
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
}
