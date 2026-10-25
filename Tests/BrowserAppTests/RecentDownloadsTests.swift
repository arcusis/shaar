import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct RecentDownloadsTests {
  private let id = "8ce51349-a188-4bad-bd1c-011b48e48ca6"

  @Test func completedReadableRegularFileIsAllowedOnlyForCurrentProfile() throws {
    let model = DownloadsModel()
    let profile = UUID()
    let otherProfile = UUID()
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("recent-download-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("download".utf8).write(to: file)
    model.changed(record(path: file.path, state: "finished"), profileID: profile)

    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == file)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: otherProfile) == nil)
  }

  @Test func missingDirectoryIncompleteDangerousAndPrivateFilesAreRejected() throws {
    let model = DownloadsModel()
    let profile = UUID()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("recent-download-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("download.txt")
    try Data("download".utf8).write(to: file)

    model.changed(record(path: directory.path, state: "finished"), profileID: profile)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
    model.changed(record(path: "/missing/recent-download", state: "finished"), profileID: profile)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
    model.changed(record(path: file.path, state: "downloading"), profileID: profile)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
    model.changed(
      record(path: file.path, state: "finished", dangerous: true), profileID: profile)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
    let privateModel = DownloadsModel()
    privateModel.changed(
      record(path: file.path, state: "finished", privateItem: true), profileID: profile)
    #expect(privateModel.items(in: profile).isEmpty)
    #expect(privateModel.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
  }

  @Test func removedAndChangedRecordsAreRevalidatedAtDragStart() throws {
    let model = DownloadsModel()
    let profile = UUID()
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("recent-download-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("download".utf8).write(to: file)
    model.changed(record(path: file.path, state: "finished"), profileID: profile)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) != nil)

    model.changed(record(path: file.path, state: "downloading"), profileID: profile)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
    model.changed(record(path: file.path, state: "finished"), profileID: profile)
    try FileManager.default.removeItem(at: file)
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
    try Data("download".utf8).write(to: file)
    model.changed(record(path: file.path, state: "finished"), profileID: profile)
    model.removed(id, profileID: profile)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(model.fileForDrag(id: id, profileID: profile, selectedProfileID: profile) == nil)
  }

  private func record(
    path: String, state: String, dangerous: Bool = false, privateItem: Bool = false
  ) -> [String: Any] {
    [
      "id": id, "filename": "file.txt", "path": path, "url": "https://example.com/file",
      "state": state, "paused": false, "dangerous": dangerous, "offTheRecord": privateItem,
      "received": 20.0, "total": 100.0, "startTime": 1.0,
    ]
  }
}
