import AppKit
import BrowserCore
import Observation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct LibraryDownloadsView: View {
  let store: BrowserStore
  let profileID: UUID
  let mediaOnly: Bool

  private let injectedDownloads: DownloadsModel?
  @State private var search = ""
  @State private var statusFilter: LibraryDownloadStatusFilter = .all
  @State private var mediaKind: LibraryMediaKind?
  @State private var thumbnails = LibraryThumbnailLoader()
  @FocusState private var searchIsFocused: Bool

  init(store: BrowserStore, profileID: UUID, mediaOnly: Bool) {
    self.store = store
    self.profileID = profileID
    self.mediaOnly = mediaOnly
    injectedDownloads = nil
  }

  init(
    store: BrowserStore, profileID: UUID, mediaOnly: Bool, downloads: DownloadsModel?
  ) {
    self.store = store
    self.profileID = profileID
    self.mediaOnly = mediaOnly
    injectedDownloads = downloads
  }

  private var currentProfileID: UUID { store.session.selectedSpace.profileID }
  private var profileIsCurrent: Bool { currentProfileID == profileID }
  private var downloads: DownloadsModel? { injectedDownloads ?? store.engine?.downloads }
  private var items: [BrowserDownload] {
    guard profileIsCurrent, let downloads else { return [] }
    let results = LibraryDownloadQuery.filtered(
      downloads.items(in: profileID), search: search,
      mediaOnly: mediaOnly, kind: mediaKind, profileID: profileID,
      currentProfileID: currentProfileID,
      downloads: downloads)
    if mediaOnly { return results }
    return results.filter(statusFilter.includes)
  }

  var body: some View {
    let visibleItems = items
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        TextField(mediaOnly ? "Search Media" : "Search Downloads", text: $search)
          .textFieldStyle(.roundedBorder)
          .focused($searchIsFocused)
          .accessibilityLabel(mediaOnly ? "Search Media" : "Search Downloads")
          .onSubmit {}
        if mediaOnly {
          Picker("Media type", selection: $mediaKind) {
            Text("All").tag(LibraryMediaKind?.none)
            ForEach(LibraryMediaKind.allCases) { kind in
              Text(kind.rawValue).tag(Optional(kind))
            }
          }
          .pickerStyle(.menu)
          .accessibilityLabel("Media type")
        } else {
          Picker("Download status", selection: $statusFilter) {
            ForEach(LibraryDownloadStatusFilter.allCases) { filter in
              Text(filter.rawValue).tag(filter)
            }
          }
          .pickerStyle(.menu)
          .accessibilityLabel("Download status")
        }
      }

      if !profileIsCurrent {
        ContentUnavailableView("Profile changed", systemImage: "person.crop.circle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if downloads == nil {
        ContentUnavailableView("Downloads unavailable", systemImage: "arrow.down.circle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if visibleItems.isEmpty {
        ContentUnavailableView(
          filtersAreActive ? "No matches" : emptyTitle,
          systemImage: mediaOnly ? "photo.on.rectangle.angled" : "arrow.down.circle",
          description: Text(filtersAreActive ? "Try another search or filter." : emptyDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if mediaOnly {
        mediaGrid(visibleItems)
      } else {
        downloadList(visibleItems)
      }

      if profileIsCurrent, let notice = downloads?.notices[profileID] {
        Text(notice).font(.callout).foregroundStyle(.secondary)
          .accessibilityLabel("Download notice: \(notice)")
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { searchIsFocused = true }
    .onChange(of: currentProfileID) { _, _ in thumbnails.clear() }
  }

  private var filtersAreActive: Bool {
    !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (mediaOnly ? mediaKind != nil : statusFilter != .all)
  }

  private var emptyTitle: String {
    mediaOnly ? "No downloaded media" : "No downloads"
  }

  private var emptyDescription: String {
    mediaOnly
      ? "Downloaded images, videos, and PDFs appear here."
      : "Downloads for this profile appear here."
  }

  private func downloadList(_ items: [BrowserDownload]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        ForEach(LibraryDownloadQuery.dateGroups(items)) { group in
          LazyVStack(alignment: .leading, spacing: 0) {
            Text(group.date.formatted(date: .complete, time: .omitted))
              .font(.headline)
              .padding(.bottom, 4)
            ForEach(group.items) { item in
              downloadRow(item)
              Divider()
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityLabel("Chronological downloads")
  }

  private func downloadRow(_ item: BrowserDownload) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Group {
        if item.dangerous {
          Image(systemName: "exclamationmark.shield")
        } else {
          Image(nsImage: fileIcon(for: item))
            .resizable().scaledToFit().frame(width: 22, height: 22)
        }
      }
      .font(.title3).foregroundStyle(.secondary).frame(width: 26)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.filename).font(.headline).lineLimit(1).truncationMode(.middle)
        Text("\(item.source) · \(LibraryDownloadQuery.status(item)) · \(fileType(item))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if item.state == .downloading && !item.dangerous {
          if let progress = item.progress {
            ProgressView(value: progress)
          } else {
            ProgressView().controlSize(.small)
          }
          Text(byteStatus(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if item.dangerous {
          Text("Blocked by the browser. This file cannot be opened here.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if item.canOpen {
        Button {
          guard canUseFileActions else { return }
          store.engine?.revealDownload(item.id, profileID: profileID, open: true)
        } label: {
          Image(systemName: "arrow.up.forward.square")
        }
        .help("Open file")
        .accessibilityLabel("Open \(item.filename)")
        .disabled(!canUseFileActions)
        Button {
          guard canUseFileActions else { return }
          store.engine?.revealDownload(item.id, profileID: profileID, open: false)
        } label: {
          Image(systemName: "folder")
        }
        .help("Show in Finder")
        .accessibilityLabel("Show \(item.filename) in Finder")
        .disabled(!canUseFileActions)
      }
      ForEach(item.actions, id: \.rawValue) { action in
        Button {
          guard canUseDownloadActions, let downloads else { return }
          downloads.perform(
            action, id: item.id, profileID: profileID, selectedProfileID: currentProfileID)
        } label: {
          Image(systemName: symbol(action))
        }
        .help(actionLabel(action))
        .accessibilityLabel("\(actionLabel(action)): \(item.filename)")
        .disabled(!canUseDownloadActions)
      }
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.vertical, 9)
  }

  private func mediaGrid(_ items: [BrowserDownload]) -> some View {
    let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]
    return ScrollView {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
        ForEach(items) { item in
          if let downloads,
            let media = LibraryDownloadQuery.mediaFile(
              for: item, profileID: profileID, currentProfileID: currentProfileID,
              downloads: downloads)
          {
            mediaCard(item, media: media, downloads: downloads)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityLabel("Downloaded media")
  }

  private var canUseDownloadActions: Bool {
    profileIsCurrent && store.sheet == nil && !store.commandIsOpen
  }

  private var canUseFileActions: Bool {
    canUseDownloadActions && store.engine != nil
  }

  private func mediaCard(
    _ item: BrowserDownload, media: LibraryMediaFile, downloads: DownloadsModel
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
        if let image = thumbnails.image(for: item, media: media, profileID: profileID) {
          Image(nsImage: image).resizable().scaledToFit().padding(5)
        } else {
          Image(systemName: media.kind.symbol)
            .font(.system(size: 30)).foregroundStyle(.secondary)
        }
      }
      .frame(height: 112)
      .task(id: thumbnailTaskID(item, media: media)) {
        await thumbnails.load(
          item, media: media, profileID: profileID, store: store, downloads: downloads)
      }
      Text(item.filename).font(.callout.weight(.medium)).lineLimit(2)
      Text("\(media.kind.rawValue) · Complete · \(item.source)")
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      HStack(spacing: 8) {
        Button("Open") {
          guard canUseFileActions else { return }
          store.engine?.revealDownload(item.id, profileID: profileID, open: true)
        }
        .accessibilityLabel("Open \(item.filename)")
        .disabled(!canUseFileActions)
        Button("Show in Finder") {
          guard canUseFileActions else { return }
          store.engine?.revealDownload(item.id, profileID: profileID, open: false)
        }
        .accessibilityLabel("Show \(item.filename) in Finder")
        .disabled(!canUseFileActions)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .onChange(of: downloads.records[profileID]?[item.id]) { _, _ in
      thumbnails.remove(item, profileID: profileID)
    }
  }

  private func thumbnailTaskID(_ item: BrowserDownload, media: LibraryMediaFile) -> String {
    "\(currentProfileID.uuidString):\(item.id):\(media.url.path)"
  }

  private func fileType(_ item: BrowserDownload) -> String {
    guard let url = item.fileURL, let type = UTType(filenameExtension: url.pathExtension),
      let description = type.localizedDescription
    else { return "File" }
    return description
  }

  private func fileIcon(for item: BrowserDownload) -> NSImage {
    guard let url = item.fileURL,
      let type = UTType(filenameExtension: url.pathExtension.lowercased())
    else { return NSWorkspace.shared.icon(for: UTType.data) }
    return NSWorkspace.shared.icon(for: type)
  }

  private func byteStatus(_ item: BrowserDownload) -> String {
    let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
    guard let total = item.totalBytes else { return received }
    return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
  }

  private func symbol(_ action: DownloadAction) -> String {
    switch action {
    case .pause: "pause.fill"
    case .resume: "play.fill"
    case .cancel: "xmark"
    case .remove: "minus.circle"
    }
  }

  private func actionLabel(_ action: DownloadAction) -> String {
    switch action {
    case .pause: "Pause"
    case .resume: "Resume"
    case .cancel: "Cancel download"
    case .remove: "Remove from list"
    }
  }
}

@MainActor @Observable
private final class LibraryThumbnailLoader {
  private var images: [String: NSImage] = [:]
  private var cacheOrder: [String] = []
  private var active: Set<String> = []
  private let maximumConcurrentRequests = 3
  private let maximumCachedImages = 64

  func image(for item: BrowserDownload, media: LibraryMediaFile, profileID: UUID) -> NSImage? {
    images[key(item, media: media, profileID: profileID)]
  }

  func remove(_ item: BrowserDownload, profileID: UUID) {
    let prefix = "\(profileID.uuidString):\(item.id):"
    images = images.filter { !$0.key.hasPrefix(prefix) }
    cacheOrder.removeAll { $0.hasPrefix(prefix) }
  }

  func clear() {
    images.removeAll()
    cacheOrder.removeAll()
  }

  func load(
    _ item: BrowserDownload,
    media: LibraryMediaFile,
    profileID: UUID,
    store: BrowserStore,
    downloads: DownloadsModel
  ) async {
    let cacheKey = key(item, media: media, profileID: profileID)
    guard images[cacheKey] == nil else { return }
    while active.count >= maximumConcurrentRequests {
      guard !Task.isCancelled else { return }
      do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
    }
    guard !Task.isCancelled,
      let safeFile = LibraryDownloadQuery.mediaFile(
        for: item, profileID: profileID,
        currentProfileID: store.session.selectedSpace.profileID, downloads: downloads),
      safeFile == media
    else { return }

    active.insert(cacheKey)
    defer { active.remove(cacheKey) }
    let request = QLThumbnailGenerator.Request(
      fileAt: safeFile.url,
      size: CGSize(width: 260, height: 180),
      scale: NSScreen.main?.backingScaleFactor ?? 2,
      representationTypes: .all)
    guard
      let result = await generate(request)?.representation,
      !Task.isCancelled,
      store.session.selectedSpace.profileID == profileID,
      downloads.records[profileID]?[item.id] == item,
      LibraryDownloadQuery.mediaFile(
        for: item, profileID: profileID, currentProfileID: store.session.selectedSpace.profileID,
        downloads: downloads) == media
    else { return }
    images[cacheKey] = NSImage(cgImage: result.cgImage, size: .zero)
    cacheOrder.removeAll { $0 == cacheKey }
    cacheOrder.append(cacheKey)
    while cacheOrder.count > maximumCachedImages {
      images[cacheOrder.removeFirst()] = nil
    }
  }

  private func generate(_ request: QLThumbnailGenerator.Request) async -> ThumbnailResult? {
    let handle = LibraryThumbnailRequest(request)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
          representation, _ in
          continuation.resume(returning: representation.map(ThumbnailResult.init))
        }
      }
    } onCancel: {
      handle.cancel()
    }
  }

  private func key(_ item: BrowserDownload, media: LibraryMediaFile, profileID: UUID) -> String {
    "\(profileID.uuidString):\(item.id):\(media.url.path)"
  }
}

private final class LibraryThumbnailRequest: @unchecked Sendable {
  private let request: QLThumbnailGenerator.Request

  init(_ request: QLThumbnailGenerator.Request) { self.request = request }

  func cancel() { QLThumbnailGenerator.shared.cancel(request) }
}

private final class ThumbnailResult: @unchecked Sendable {
  let representation: QLThumbnailRepresentation

  init(_ representation: QLThumbnailRepresentation) { self.representation = representation }
}
