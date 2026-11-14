// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import UniformTypeIdentifiers

enum LibraryMediaKind: String, CaseIterable, Identifiable {
  case image = "Images"
  case video = "Videos"
  case pdf = "PDFs"

  var id: String { rawValue }

  var title: String { PanelsL10n.string(rawValue) }

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

  var title: String { PanelsL10n.string(rawValue) }

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

struct LibraryMediaDownload: Identifiable {
  let item: BrowserDownload
  let file: LibraryMediaFile

  var id: String { item.id }
}

struct LibraryDownloadDateGroup: Identifiable {
  let date: Date
  let items: [BrowserDownload]

  var id: Date { date }
}

@MainActor
enum LibraryDownloadQuery {
  static func quickLookURL(
    for item: BrowserDownload,
    profileID: UUID,
    currentProfileID: UUID,
    downloads: DownloadsModel
  ) -> URL? {
    guard profileID == currentProfileID, item.profileID == profileID, item.canOpen,
      downloads.libraryItem(id: item.id, profileID: profileID) == item
    else { return nil }
    return downloads.fileForDrag(
      id: item.id, profileID: profileID, selectedProfileID: currentProfileID)
  }

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
      return item.filename.localizedStandardContains(query)
    }
  }

  static func mediaResults(
    _ items: [BrowserDownload], search: String, kind: LibraryMediaKind?,
    profileID: UUID, currentProfileID: UUID, downloads: DownloadsModel
  ) -> [LibraryMediaDownload] {
    guard profileID == currentProfileID else { return [] }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.compactMap { item in
      guard item.profileID == profileID,
        let file = mediaFile(
          for: item, profileID: profileID, currentProfileID: currentProfileID,
          downloads: downloads),
        kind == nil || file.kind == kind,
        query.isEmpty || item.filename.localizedStandardContains(query)
      else { return nil }
      return LibraryMediaDownload(item: item, file: file)
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
    var groupedItems: [(date: Date, label: String, items: [BrowserDownload])] = []
    var previousDate: Date?
    var previousLabel: String?
    for item in sorted {
      let date = calendar.startOfDay(for: Date(timeIntervalSince1970: item.startTime))
      let label: String
      if date == previousDate, let previousLabel {
        label = previousLabel
      } else {
        label = relativeDay(date, now: now, calendar: calendar)
        previousDate = date
        previousLabel = label
      }
      if groupedItems.last?.date == date {
        groupedItems[groupedItems.count - 1].items.append(item)
        continue
      }
      if groupedItems.last?.label == label {
        groupedItems[groupedItems.count - 1].items.append(item)
      } else {
        groupedItems.append((date: date, label: label, items: [item]))
      }
    }
    return groupedItems.map { LibraryDownloadDateGroup(date: $0.date, items: $0.items) }
  }

  static func relativeDay(
    _ date: Date, now: Date = Date(), calendar: Calendar = .current,
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    let days = max(
      0,
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)
      ).day ?? 0)
    if days == 0 { return BrowserLocalization.string("Today", table: "Panels", language: language) }
    if days == 1 {
      return BrowserLocalization.string("Yesterday", table: "Panels", language: language)
    }
    if days < 7 {
      return BrowserLocalization.plural(
        "%d days ago", count: days, table: "Panels", language: language)
    }
    if days < 30 {
      let weeks = days / 7
      return BrowserLocalization.plural(
        weeks == 1 ? "%d week ago" : "%d weeks ago", count: weeks, table: "Panels",
        language: language)
    }
    let years = max(
      0,
      calendar.dateComponents(
        [.year], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
      ).year ?? 0)
    if years > 0 {
      return BrowserLocalization.plural(
        "%d years ago", count: years, table: "Panels", language: language)
    }
    let months = max(1, days / 30)
    return BrowserLocalization.plural(
      months == 1 ? "%d month ago" : "%d months ago", count: months, table: "Panels",
      language: language)
  }

  static func status(_ item: BrowserDownload) -> String {
    if item.dangerous { return PanelsL10n.string("Blocked") }
    return switch item.state {
    case .downloading: PanelsL10n.string(item.paused ? "Paused" : "Downloading")
    case .finished: PanelsL10n.string("Complete")
    case .failed: PanelsL10n.string("Interrupted")
    case .cancelled: PanelsL10n.string("Cancelled")
    }
  }
}
