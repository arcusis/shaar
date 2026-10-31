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
struct LibraryDownloadTests {
  private func record(
    _ id: String = UUID().uuidString.lowercased(),
    filename: String = "sample.jpg",
    path: String = "/tmp/sample.jpg",
    state: String = "finished",
    dangerous: Bool = false,
    start: Double = 1_800_000_000,
    source: String = "https://example.test/file"
  ) -> [String: Any] {
    [
      "id": id, "filename": filename, "path": path, "url": source,
      "state": state, "paused": false, "dangerous": dangerous, "offTheRecord": false,
      "received": 100.0, "total": 100.0, "startTime": start,
    ]
  }

  @Test func classifiesOnlyReadableFinishedCurrentProfileDownloads() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appending(path: "preview.png")
    let videoURL = root.appending(path: "clip.mp4")
    let pdfURL = root.appending(path: "report.pdf")
    let textURL = root.appending(path: "notes.txt")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)
    try Data("authored fixture video bytes".utf8).write(to: videoURL)
    try Data("%PDF-1.4".utf8).write(to: pdfURL)
    try Data("notes".utf8).write(to: textURL)

    let profile = UUID()
    let otherProfile = UUID()
    let model = DownloadsModel()
    let imageID = UUID().uuidString.lowercased()
    let videoID = UUID().uuidString.lowercased()
    let pdfID = UUID().uuidString.lowercased()
    let textID = UUID().uuidString.lowercased()
    let missingID = UUID().uuidString.lowercased()
    let downloadingID = UUID().uuidString.lowercased()
    let dangerousID = UUID().uuidString.lowercased()
    let directoryID = UUID().uuidString.lowercased()
    model.restore(
      [
        record(imageID, filename: "preview.png", path: imageURL.path),
        record(videoID, filename: "clip.mp4", path: videoURL.path),
        record(pdfID, filename: "report.pdf", path: pdfURL.path),
        record(textID, filename: "notes.txt", path: textURL.path),
        record(missingID, filename: "missing.png", path: root.appending(path: "missing.png").path),
        record(downloadingID, filename: "partial.png", path: imageURL.path, state: "downloading"),
        record(dangerousID, filename: "blocked.png", path: imageURL.path, dangerous: true),
        record(directoryID, filename: "folder.png", path: root.path),
      ], profileID: profile)

    let image = try #require(model.items(in: profile).first { $0.id == imageID })
    let video = try #require(model.items(in: profile).first { $0.id == videoID })
    let pdf = try #require(model.items(in: profile).first { $0.id == pdfID })
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: image, profileID: profile, currentProfileID: profile, downloads: model)?.kind == .image
    )
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: pdf, profileID: profile, currentProfileID: profile, downloads: model)?.kind == .pdf)
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: video, profileID: profile, currentProfileID: profile, downloads: model)?.kind
        == .video)
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: image, profileID: profile, currentProfileID: otherProfile, downloads: model) == nil)
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "report", mediaOnly: true, profileID: profile,
        currentProfileID: profile, downloads: model
      ).map(\.id) == [pdfID])
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "", mediaOnly: true, profileID: profile,
        currentProfileID: otherProfile, downloads: model
      ).isEmpty)
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "", mediaOnly: true, profileID: profile,
        currentProfileID: profile, downloads: model
      ).map(\.id).sorted()
        == [imageID, videoID, pdfID].sorted())
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "report", mediaOnly: true, kind: .image,
        profileID: profile, currentProfileID: profile, downloads: model
      ).isEmpty)
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "report", mediaOnly: true, kind: .pdf,
        profileID: profile, currentProfileID: profile, downloads: model
      ).map(\.id) == [pdfID])
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), kind: .image, profileID: profile,
        currentProfileID: profile, downloads: model
      ).map(\.id) == [imageID])
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), kind: .pdf, profileID: profile,
        currentProfileID: profile, downloads: model
      ).map(\.id) == [pdfID])
    let missing = try #require(model.items(in: profile).first { $0.id == missingID })
    let directory = try #require(model.items(in: profile).first { $0.id == directoryID })
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: missing, profileID: profile, currentProfileID: profile, downloads: model) == nil)
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: directory, profileID: profile, currentProfileID: profile, downloads: model) == nil)

    model.changed(
      record(imageID, filename: "replacement.png", path: imageURL.path), profileID: profile)
    #expect(
      LibraryDownloadQuery.mediaFile(
        for: image, profileID: profile, currentProfileID: profile, downloads: model) == nil)
  }

  @Test func searchAndDateGroupsUseDownloadMetadataAndChronologicalOrder() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let profile = UUID()
    let model = DownloadsModel()
    let newestID = UUID().uuidString.lowercased()
    let sameDayID = UUID().uuidString.lowercased()
    let olderID = UUID().uuidString.lowercased()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let start = calendar.startOfDay(for: base).timeIntervalSince1970
    model.restore(
      [
        record(newestID, filename: "Newest.pdf", start: start + 60),
        record(sameDayID, filename: "Earlier.pdf", start: start + 10),
        record(olderID, filename: "Yesterday.pdf", start: start - 86_400),
      ], profileID: profile)

    let groups = LibraryDownloadQuery.dateGroups(
      model.items(in: profile), calendar: calendar, now: base)
    #expect(groups.count == 2)
    #expect(groups[0].items.map(\.id) == [newestID, sameDayID])
    #expect(groups[1].items.map(\.id) == [olderID])
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "yesterday", profileID: profile,
        currentProfileID: profile, downloads: model
      ).map(\.id) == [olderID])
    #expect(
      LibraryDownloadQuery.filtered(
        model.items(in: profile), search: "example.test", profileID: profile,
        currentProfileID: profile, downloads: model
      ).isEmpty)
  }

  @Test func fileTypeFiltersAndRelativeDates() throws {
    let profile = UUID()
    let model = DownloadsModel()
    model.restore(
      [
        record(filename: "photo.png"), record(filename: "clip.mp4"),
        record(filename: "report.pdf"), record(filename: "bundle.zip"),
      ], profileID: profile)
    let items = model.items(in: profile)
    #expect(
      items.filter(LibraryDownloadTypeFilter.images.includes).map(\.filename) == ["photo.png"])
    #expect(items.filter(LibraryDownloadTypeFilter.videos.includes).map(\.filename) == ["clip.mp4"])
    #expect(
      items.filter(LibraryDownloadTypeFilter.documents.includes).map(\.filename) == ["report.pdf"])
    #expect(
      items.filter(LibraryDownloadTypeFilter.archives.includes).map(\.filename) == ["bundle.zip"])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (days, label) in [
      (0, "Today"), (1, "Yesterday"), (3, "3 days ago"),
      (7, "1 week ago"), (60, "2 months ago"),
    ] {
      let date = try #require(calendar.date(byAdding: .day, value: -days, to: now))
      #expect(LibraryDownloadQuery.relativeDay(date, now: now, calendar: calendar) == label)
    }
  }

  @Test func capturesActualDownloadsAndMediaComponentsAcrossStates() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "browser-library-download-captures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let captureRoot = URL(filePath: "/tmp/browser-library-download-review")
    try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)

    let currentProfile = BrowserProfile(name: "Current")
    let oldProfile = BrowserProfile(name: "Previous")
    let currentSpace = BrowserSpace(
      profileID: currentProfile.id, name: "Current", symbol: "circle", tint: .ocean)
    let oldSpace = BrowserSpace(
      profileID: oldProfile.id, name: "Previous", symbol: "circle", tint: .rose)
    let session = try BrowserSession(
      profiles: [currentProfile, oldProfile], spaces: [currentSpace, oldSpace],
      selectedSpaceID: currentSpace.id)
    let store = BrowserStore(sessionFile: nil, session: session)
    let imageURL = root.appending(path: "authored-image.png")
    let pdfURL = root.appending(path: "authored-document.pdf")
    try makePNGFixture().write(to: imageURL)
    try makePDFFixture().write(to: pdfURL)

    let downloads = DownloadsModel()
    let imageID = UUID().uuidString.lowercased()
    let pdfID = UUID().uuidString.lowercased()
    downloads.restore(
      [
        record(imageID, filename: "authored-image.png", path: imageURL.path),
        record(pdfID, filename: "authored-document.pdf", path: pdfURL.path),
      ], profileID: currentProfile.id)

    try await capture(
      LibraryDownloadsView(
        store: store, profileID: currentProfile.id, mediaOnly: false, downloads: downloads),
      size: NSSize(width: 300, height: 520), appearance: .aqua,
      to: captureRoot.appending(path: "populated-downloads.png"))
    let mediaCapture = try await capture(
      LibraryDownloadsView(
        store: store, profileID: currentProfile.id, mediaOnly: true, downloads: downloads),
      size: NSSize(width: 300, height: 520), appearance: .aqua,
      to: captureRoot.appending(path: "populated-media.png"),
      ready: { blueThumbnailSampleCount($0) > 200 })
    let blueSamples = blueThumbnailSampleCount(mediaCapture)
    #expect(blueSamples > 200, "Authored blue image must render as a real thumbnail.")
    try await capture(
      LibraryDownloadsView(
        store: store, profileID: currentProfile.id, mediaOnly: false, downloads: DownloadsModel()),
      size: NSSize(width: 300, height: 520), appearance: .aqua,
      to: captureRoot.appending(path: "empty-downloads.png"))
    try await capture(
      LibraryDownloadsView(
        store: store, profileID: currentProfile.id, mediaOnly: true, downloads: downloads
      )
      .environment(\.colorScheme, .dark),
      size: NSSize(width: 300, height: 520), appearance: .darkAqua,
      to: captureRoot.appending(path: "dark-media.png"), settleMilliseconds: 1200)
    try await capture(
      LibraryDownloadsView(
        store: store, profileID: currentProfile.id, mediaOnly: true, downloads: downloads),
      size: NSSize(width: 320, height: 600), appearance: .aqua,
      to: captureRoot.appending(path: "compact-media.png"), settleMilliseconds: 1200)

    store.perform(.space(oldSpace.id))
    try await capture(
      LibraryDownloadsView(
        store: store, profileID: currentProfile.id, mediaOnly: true, downloads: downloads),
      size: NSSize(width: 300, height: 520), appearance: .aqua,
      to: captureRoot.appending(path: "stale-profile.png"))

    for name in [
      "populated-downloads.png", "populated-media.png", "empty-downloads.png",
      "dark-media.png", "compact-media.png", "stale-profile.png",
    ] {
      #expect(FileManager.default.fileExists(atPath: captureRoot.appending(path: name).path))
    }
  }

  @Test func folderFilesMergeAndCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "image.png")
    let pdf = root.appending(path: "report.pdf")
    try makePNGFixture().write(to: image)
    try makePDFFixture().write(to: pdf)
    try Data().write(to: root.appending(path: ".hidden"))
    try Data().write(to: root.appending(path: "partial.crdownload"))
    try Data().write(to: root.appending(path: "partial.download"))
    let profile = BrowserProfile(name: "Current")
    let space = BrowserSpace(profileID: profile.id, name: "Current", symbol: "circle", tint: .ocean)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let store = BrowserStore(sessionFile: nil, session: session)
    let source = DownloadsFolderSource(directory: root)
    let model = DownloadsModel(folder: source)
    #expect(model.libraryItems(in: profile.id).count == 2)
    let id = UUID().uuidString.lowercased()
    model.restore([record(id, filename: "image.png", path: image.path)], profileID: profile.id)
    let merged = model.libraryItems(in: profile.id)
    #expect(merged.count == 2)
    #expect(merged.contains { $0.id == id })
    #expect(
      LibraryDownloadQuery.filtered(
        merged, kind: .pdf, profileID: profile.id,
        currentProfileID: profile.id, downloads: model
      ).count == 1)
    let folderItem = try #require(merged.first { $0.filename == "report.pdf" })
    #expect(model.isFolderItem(folderItem, profileID: profile.id))
    #expect(
      model.fileForDrag(
        id: folderItem.id, profileID: profile.id,
        selectedProfileID: profile.id) != nil)
    try await capture(
      LibraryDownloadsView(
        store: store, profileID: profile.id,
        mediaOnly: false, downloads: model), size: NSSize(width: 300, height: 520),
      appearance: .aqua, to: URL(filePath: "/tmp/folder-downloads.png"))
    try await capture(
      LibraryDownloadsView(
        store: store, profileID: profile.id,
        mediaOnly: true, downloads: model), size: NSSize(width: 300, height: 520),
      appearance: .aqua, to: URL(filePath: "/tmp/folder-media.png"), settleMilliseconds: 1200)
    try FileManager.default.removeItem(at: pdf)
    for _ in 0..<40 where model.libraryItems(in: profile.id).count != 1 {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(model.libraryItems(in: profile.id).count == 1)
  }

  private func makePNGFixture() throws -> Data {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func makePDFFixture() -> Data {
    let stream = "BT /F1 12 Tf 10 50 Td (Authored fixture) Tj ET\n"
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
      "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    var pdf = "%PDF-1.4\n"
    var offsets = [0]
    for (index, object) in objects.enumerated() {
      offsets.append(pdf.utf8.count)
      pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xrefOffset = pdf.utf8.count
    pdf += "xref\n0 6\n0000000000 65535 f \n"
    for offset in offsets.dropFirst() {
      pdf += String(format: "%010d 00000 n \n", offset)
    }
    pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
    return Data(pdf.utf8)
  }

  private func blueThumbnailSampleCount(_ bitmap: NSBitmapImageRep) -> Int {
    let inset = Int(Double(bitmap.pixelsHigh) * 80 / 520)
    var blueSamples = 0
    for y in stride(from: inset, to: bitmap.pixelsHigh - inset, by: 4) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
          color.blueComponent > 0.65, color.redComponent < 0.3,
          color.blueComponent - color.greenComponent > 0.2
        {
          blueSamples += 1
        }
      }
    }
    return blueSamples
  }

  @discardableResult private func capture<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL,
    settleMilliseconds: Int = 200, ready: ((NSBitmapImageRep) -> Bool)? = nil
  ) async throws -> NSBitmapImageRep {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    defer { window.close() }
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(settleMilliseconds))
    host.layoutSubtreeIfNeeded()
    var bitmap = try VisualCapture.render(host, to: url)
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while let ready, !ready(bitmap), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      bitmap = try VisualCapture.render(host, to: url)
    }
    return bitmap
  }
}
