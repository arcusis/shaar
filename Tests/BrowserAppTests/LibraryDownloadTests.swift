import BrowserCore
import Foundation
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

    let groups = LibraryDownloadQuery.dateGroups(model.items(in: profile), calendar: calendar)
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
      ).count == 3)
  }
}
