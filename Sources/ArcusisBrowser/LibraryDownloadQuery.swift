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

enum LibraryDownloadTypeFilter: String, CaseIterable, Identifiable {
  case all = "All"
  case images = "Images"
  case videos = "Videos"
  case documents = "Documents"
  case archives = "Archives"
  var id: String { rawValue }

  func includes(_ item: BrowserDownload) -> Bool {
    guard self != .all else { return true }
    let ext = (item.filename as NSString).pathExtension.lowercased()
    guard let type = UTType(filenameExtension: ext) else { return false }
    switch self {
    case .all: return true
    case .images: return type.conforms(to: .image)
    case .videos: return type.conforms(to: .movie) || type.conforms(to: .video)
    case .documents:
      return type.conforms(to: .content) && !type.conforms(to: .image)
        && !type.conforms(to: .movie) && !type.conforms(to: .video) && !type.conforms(to: .archive)
    case .archives: return type.conforms(to: .archive)
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
      downloads.libraryItem(id: item.id, profileID: profileID) == item,
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
    kind: LibraryMediaKind? = nil,
    profileID: UUID, currentProfileID: UUID, downloads: DownloadsModel
  ) -> [BrowserDownload] {
    guard profileID == currentProfileID else { return [] }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter { item in
      guard item.profileID == profileID else { return false }
      if mediaOnly {
        guard
          let media = mediaFile(
            for: item, profileID: profileID, currentProfileID: currentProfileID,
            downloads: downloads), kind == nil || media.kind == kind
        else { return false }
      }
      guard !query.isEmpty else { return true }
      return item.filename.localizedCaseInsensitiveContains(query)
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

  static func dateGroups(
    _ items: [BrowserDownload], calendar: Calendar = .current, now: Date = Date()
  )
    -> [LibraryDownloadDateGroup]
  {
    let sorted = items.sorted {
      $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime > $1.startTime
    }
    var groups: [LibraryDownloadDateGroup] = []
    for item in sorted {
      let date = calendar.startOfDay(for: Date(timeIntervalSince1970: item.startTime))
      if let last = groups.last,
        relativeDay(last.date, now: now, calendar: calendar)
          == relativeDay(date, now: now, calendar: calendar)
      {
        groups[groups.count - 1] = LibraryDownloadDateGroup(
          date: last.date, items: last.items + [item])
      } else {
        groups.append(LibraryDownloadDateGroup(date: date, items: [item]))
      }
    }
    return groups
  }

  static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String
  {
    let days = max(
      0,
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)
      ).day ?? 0)
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 7 { return "\(days) days ago" }
    if days < 30 {
      let weeks = days / 7
      return "\(weeks) \(weeks == 1 ? "week" : "weeks") ago"
    }
    let months = max(1, days / 30)
    return "\(months) \(months == 1 ? "month" : "months") ago"
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
