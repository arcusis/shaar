// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
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

  @Test func recentPopoverRendersFixedDateFixtures() throws {
    let profile = UUID(uuidString: "43b4d66a-1f9e-4fb8-91b2-7b7bda489a01")!
    let referenceDate = Date(timeIntervalSince1970: 1_798_000_000)
    let items = [
      download(
        profile: profile, filename: "Arcusis-Release.dmg", state: .finished,
        startTime: referenceDate.timeIntervalSince1970 - 3_600),
      download(
        profile: profile, filename: "research-notes.pdf", state: .downloading,
        startTime: referenceDate.timeIntervalSince1970 - 120, received: 65_536, total: 262_144),
      download(
        profile: profile, filename: "image-export.zip", state: .downloading, paused: true,
        startTime: referenceDate.timeIntervalSince1970 - 300, received: 1_048_576),
      download(
        profile: profile, filename: "blocked-file.dmg", state: .failed, dangerous: true,
        startTime: referenceDate.timeIntervalSince1970 - 600),
      download(
        profile: profile, filename: "failed-report.csv", state: .failed,
        startTime: referenceDate.timeIntervalSince1970 - 900),
    ]
    let output = URL(fileURLWithPath: "/tmp/browser-recent-polish", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    try capture(
      items: items, profile: profile, referenceDate: referenceDate,
      scheme: .light, width: 300, name: "normal", output: output)
    try capture(
      items: items, profile: profile, referenceDate: referenceDate,
      scheme: .dark, width: 300, name: "dark", output: output)
    try capture(
      items: [], profile: profile, referenceDate: referenceDate,
      scheme: .light, width: 300, name: "empty", output: output)
    try capture(
      items: [items[0]], profile: profile, referenceDate: referenceDate,
      scheme: .light, width: 300, name: "minimum", output: output)
    try capture(
      items: [
        download(
          profile: profile,
          filename: "تقرير־مراجعة־مهم־非常に長いファイル名_日本語-💾.pdf",
          state: .finished, startTime: referenceDate.timeIntervalSince1970 - 86_400)
      ],
      profile: profile, referenceDate: referenceDate,
      scheme: .light, width: 300, name: "long-name-rtl-unicode", output: output)
  }

  private func capture(
    items: [BrowserDownload], profile: UUID, referenceDate: Date,
    scheme: ColorScheme, width: CGFloat, name: String, output: URL
  ) throws {
    let view = RecentDownloadsPopover(
      items: items, profileID: profile, selectedProfileID: { profile },
      dragURL: { _ in nil }, dismiss: {}, referenceDate: referenceDate,
      animatesReveal: false
    )
    .environment(\.colorScheme, scheme)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: 420)
    host.layoutSubtreeIfNeeded()
    _ = try VisualCapture.render(
      host, to: output.appendingPathComponent("\(name).png"))
  }

  private func download(
    profile: UUID, filename: String, state: DownloadState, paused: Bool = false,
    dangerous: Bool = false, startTime: Double, received: Double = 0, total: Double = -1
  ) -> BrowserDownload {
    BrowserDownload(
      id: UUID().uuidString.lowercased(), profileID: profile, filename: filename,
      path: "", sourceURL: "https://downloads.example.test/\(filename)", state: state,
      paused: paused, dangerous: dangerous, offTheRecord: false,
      received: received, total: total, startTime: startTime
    )!
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
