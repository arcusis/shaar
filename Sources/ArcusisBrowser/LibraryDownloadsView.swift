// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
  @State private var typeFilter: LibraryDownloadTypeFilter = .all
  @State private var hoveredID: String?
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
      downloads.libraryItems(in: profileID), search: search,
      mediaOnly: mediaOnly, kind: mediaKind, profileID: profileID,
      currentProfileID: currentProfileID,
      downloads: downloads)
    if mediaOnly { return results }
    return results.filter(typeFilter.includes)
  }

  var body: some View {
    let visibleItems = items
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(mediaOnly ? "Search Media..." : "Search Downloads...", text: $search)
            .textFieldStyle(.plain)
            .focused($searchIsFocused)
            .accessibilityLabel(mediaOnly ? "Search Media" : "Search Downloads")
        }
        .font(.system(size: 15))
        .padding(.horizontal, 10).frame(height: 36)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        if !mediaOnly {
          Menu {
            Picker("Filter", selection: $typeFilter) {
              ForEach(LibraryDownloadTypeFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
              }
            }
          } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
              .font(.system(size: 14, weight: .medium))
              .padding(.horizontal, 10).frame(height: 36)
              .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
          }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("Filter downloads")
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
      || (!mediaOnly && typeFilter != .all)
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
            Text(LibraryDownloadQuery.relativeDay(group.date))
              .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
              .padding(.bottom, 4)
            ForEach(group.items) { item in
              downloadRow(item)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityLabel("Chronological downloads")
  }

  private func downloadRow(_ item: BrowserDownload) -> some View {
    let media = downloads.flatMap {
      LibraryDownloadQuery.mediaFile(
        for: item, profileID: profileID,
        currentProfileID: currentProfileID, downloads: $0)
    }
    return HStack(spacing: 10) {
      Group {
        if item.dangerous {
          Image(systemName: "exclamationmark.shield").foregroundStyle(.secondary)
        } else if let media,
          let image = thumbnails.image(for: item, media: media, profileID: profileID)
        {
          Image(nsImage: image).resizable().scaledToFit()
        } else {
          Image(nsImage: fileIcon(for: item)).resizable().scaledToFit()
        }
      }.frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.filename).font(.system(size: 15)).lineLimit(1).truncationMode(.tail)
        Text(subtitle(item)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        if item.state == .downloading && !item.dangerous {
          if let progress = item.progress {
            ProgressView(value: progress)
          } else {
            ProgressView().controlSize(.small)
          }
          Text(byteStatus(item)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        if item.dangerous {
          Text("Blocked by the browser. This file cannot be opened here.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        if item.canOpen {
          Button("Show in Finder") { open(item, inFinder: true) }.disabled(!canUseFileActions)
          Button("Open") { open(item, inFinder: false) }.disabled(!canUseFileActions)
        }
        ForEach(
          downloads?.isFolderItem(item, profileID: profileID) == true ? [] : item.actions,
          id: \.rawValue
        ) { action in
          Button(actionLabel(action)) {
            guard canUseDownloadActions, let downloads else { return }
            downloads.perform(
              action, id: item.id, profileID: profileID, selectedProfileID: currentProfileID)
          }.disabled(!canUseDownloadActions)
        }
      } label: {
        Image(systemName: "ellipsis").frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton).fixedSize()
      .opacity(hoveredID == item.id ? 1 : 0)
      .accessibilityLabel("Actions for \(item.filename)")
    }
    .padding(8).contentShape(Rectangle())
    .background(
      hoveredID == item.id ? Color.white.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .onHover { hoveredID = $0 ? item.id : nil }
    .onTapGesture(count: 2) { open(item, inFinder: false) }
    .onDrag { dragProvider(item) }
    .task(id: media.map { thumbnailTaskID(item, media: $0) }) {
      if let media, let downloads {
        await thumbnails.load(
          item, media: media, profileID: profileID, store: store, downloads: downloads)
      }
    }
    .onChange(of: downloads?.records[profileID]?[item.id]) { _, _ in
      thumbnails.remove(item, profileID: profileID)
    }
  }

  private func open(_ item: BrowserDownload, inFinder: Bool) {
    guard canUseFileActions, item.canOpen else { return }
    if downloads?.isFolderItem(item, profileID: profileID) == true,
      let url = downloads?.fileForDrag(
        id: item.id, profileID: profileID, selectedProfileID: currentProfileID)
    {
      if inFinder {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } else {
        NSWorkspace.shared.open(url)
      }
    } else {
      store.engine?.revealDownload(item.id, profileID: profileID, open: !inFinder)
    }
  }

  private func dragProvider(_ item: BrowserDownload) -> NSItemProvider {
    guard canUseDownloadActions,
      let url = downloads?.fileForDrag(
        id: item.id, profileID: profileID, selectedProfileID: currentProfileID)
    else { return NSItemProvider() }
    return NSItemProvider(contentsOf: url) ?? NSItemProvider()
  }

  private func subtitle(_ item: BrowserDownload) -> String {
    let kind = fileType(item)
    let host = item.source
    return ["Download", "Generated file", "Extension"].contains(host)
      ? kind : "\(kind) from \(host)"
  }

  private func mediaGrid(_ items: [BrowserDownload]) -> some View {
    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
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
    canUseDownloadActions && downloads != nil
  }

  private func mediaCard(
    _ item: BrowserDownload, media: LibraryMediaFile, downloads: DownloadsModel
  ) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))
      if let image = thumbnails.image(for: item, media: media, profileID: profileID) {
        Image(nsImage: image).resizable().scaledToFit().padding(10)
      } else {
        Image(nsImage: fileIcon(for: item)).resizable().scaledToFit().padding(25)
      }
      if media.kind == .video {
        Image(systemName: "play.fill").font(.system(size: 24)).foregroundStyle(.white)
          .shadow(radius: 3)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { open(item, inFinder: false) }
    .onDrag { dragProvider(item) }
    .accessibilityLabel(item.filename)
    .task(id: thumbnailTaskID(item, media: media)) {
      await thumbnails.load(
        item, media: media, profileID: profileID, store: store, downloads: downloads)
    }
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
      downloads.libraryItem(id: item.id, profileID: profileID) == item,
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
