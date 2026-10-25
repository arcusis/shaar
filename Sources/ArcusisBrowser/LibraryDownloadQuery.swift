import BrowserCore
import Foundation
import UniformTypeIdentifiers

enum LibraryMediaKind: String, CaseIterable, Identifiable {
  case image = "Images"
  case video = "Videos"
  case pdf = "PDFs"

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .image: "photo"
    case .video: "video"
    case .pdf: "doc.richtext"
    }
  }
}

enum LibraryDownloadStatusFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case inProgress = "In progress"
  case complete = "Complete"

  var id: String { rawValue }

  func includes(_ item: BrowserDownload) -> Bool {
    switch self {
    case .all: true
    case .inProgress: item.state == .downloading
    case .complete: item.state == .finished && !item.dangerous
    }
  }
}

struct LibraryMediaFile: Equatable {
  let kind: LibraryMediaKind
  let url: URL
}

struct LibraryDownloadDateGroup: Identifiable {
  let date: Date
  let items: [BrowserDownload]

  var id: Date { date }
}

@MainActor
enum LibraryDownloadQuery {
  static func mediaFile(
    for item: BrowserDownload,
    profileID: UUID,
    currentProfileID: UUID,
    downloads: DownloadsModel
  ) -> LibraryMediaFile? {
    guard profileID == currentProfileID, item.profileID == profileID,
      item.state == .finished, item.canOpen,
      downloads.records[profileID]?[item.id] == item,
      let url = downloads.fileForDrag(
        id: item.id, profileID: profileID, selectedProfileID: currentProfileID),
      let type = UTType(filenameExtension: url.pathExtension.lowercased())
    else { return nil }

    let kind: LibraryMediaKind?
    if type.conforms(to: .image) {
      kind = .image
    } else if type.conforms(to: .movie) || type.conforms(to: .video) {
      kind = .video
    } else if type.conforms(to: .pdf) {
      kind = .pdf
    } else {
      kind = nil
    }
    guard let kind else { return nil }
    return LibraryMediaFile(kind: kind, url: url)
  }

  static func filtered(
    _ items: [BrowserDownload], search: String, mediaOnly: Bool = false,
    profileID: UUID, currentProfileID: UUID, downloads: DownloadsModel
  ) -> [BrowserDownload] {
    guard profileID == currentProfileID else { return [] }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter { item in
      guard item.profileID == profileID else { return false }
      if mediaOnly,
        mediaFile(
          for: item, profileID: profileID, currentProfileID: currentProfileID,
          downloads: downloads) == nil
      {
        return false
      }
      guard !query.isEmpty else { return true }
      return item.filename.localizedCaseInsensitiveContains(query)
        || item.source.localizedCaseInsensitiveContains(query)
        || status(item).localizedCaseInsensitiveContains(query)
    }
  }

  static func filtered(
    _ items: [BrowserDownload], kind: LibraryMediaKind?, profileID: UUID,
    currentProfileID: UUID, downloads: DownloadsModel
  ) -> [BrowserDownload] {
    guard profileID == currentProfileID else { return [] }
    return items.filter { item in
      guard item.profileID == profileID,
        let media = mediaFile(
          for: item, profileID: profileID, currentProfileID: currentProfileID,
          downloads: downloads)
      else { return false }
      return kind == nil || media.kind == kind
    }
  }

  static func dateGroups(_ items: [BrowserDownload], calendar: Calendar = .current)
    -> [LibraryDownloadDateGroup]
  {
    let grouped = Dictionary(grouping: items) {
      calendar.startOfDay(for: Date(timeIntervalSince1970: $0.startTime))
    }
    return grouped.keys.sorted(by: >).map { date in
      LibraryDownloadDateGroup(
        date: date,
        items: grouped[date, default: []].sorted {
          $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
        })
    }
  }

  static func status(_ item: BrowserDownload) -> String {
    if item.dangerous { return "Blocked" }
    return switch item.state {
    case .downloading: item.paused ? "Paused" : "Downloading"
    case .finished: "Complete"
    case .failed: "Interrupted"
    case .cancelled: "Cancelled"
    }
  }
}
