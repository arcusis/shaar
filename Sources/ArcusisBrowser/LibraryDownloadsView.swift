// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Observation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import _QuickLook_SwiftUI

struct LibraryDownloadsView: View {
  static let downloadProgressAccessibilityTraits: AccessibilityTraits = .updatesFrequently

  let store: BrowserStore
  let profileID: UUID
  let mediaOnly: Bool

  private let injectedDownloads: DownloadsModel?
  @State private var search = ""
  @State private var typeFilter: LibraryDownloadTypeFilter = .all
  @State private var hoveredID: String?
  @State private var mediaKind: LibraryMediaKind?
  @State private var quickLookURL: URL?
  @State private var thumbnails = LibraryThumbnailLoader()
  @FocusState private var searchIsFocused: Bool
  @FocusState private var focusedActionsID: String?
  static func actionsAreVisible(isHovered: Bool, isFocused: Bool) -> Bool {
    isHovered || isFocused
  }

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

  private var mediaResults: [LibraryMediaDownload] {
    guard profileIsCurrent, let downloads else { return [] }
    return LibraryDownloadQuery.mediaResults(
      downloads.libraryItems(in: profileID), search: search, kind: mediaKind,
      profileID: profileID, currentProfileID: currentProfileID, downloads: downloads)
  }

  var body: some View {
    let visibleMedia = mediaOnly ? mediaResults : []
    let visibleItems = mediaOnly ? visibleMedia.map(\.item) : items
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          TextField(
            PanelsL10n.string(mediaOnly ? "Search Media…" : "Search Downloads…"), text: $search
          )
          .textFieldStyle(.plain)
          .focused($searchIsFocused)
          .accessibilityLabel(PanelsL10n.string(mediaOnly ? "Search Media" : "Search Downloads"))
        }
        .font(.system(size: 15))
        .padding(.horizontal, 10).frame(height: 36)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        if !mediaOnly {
          Menu {
            Picker(PanelsL10n.string("Filter"), selection: $typeFilter) {
              ForEach(LibraryDownloadTypeFilter.allCases) { filter in
                Text(filter.title).tag(filter)
              }
            }
          } label: {
            Label(PanelsL10n.string("Filter"), systemImage: "line.3.horizontal.decrease.circle")
              .font(.system(size: 14, weight: .medium))
              .padding(.horizontal, 10).frame(height: 36)
              .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
          }
          .menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel(PanelsL10n.string("Filter downloads"))
        }
      }

      if !profileIsCurrent {
        ContentUnavailableView(
          PanelsL10n.string("Profile changed"), systemImage: "person.crop.circle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if downloads == nil {
        ContentUnavailableView(
          PanelsL10n.string("Downloads unavailable"), systemImage: "arrow.down.circle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if visibleItems.isEmpty {
        ContentUnavailableView(
          filtersAreActive ? PanelsL10n.string("No matches") : emptyTitle,
          systemImage: mediaOnly ? "photo.on.rectangle.angled" : "arrow.down.circle",
          description: Text(
            filtersAreActive ? PanelsL10n.string("Try another search or filter.") : emptyDescription
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if mediaOnly {
        mediaGrid(visibleMedia)
      } else {
        downloadList(visibleItems)
      }

      if profileIsCurrent, let notice = downloads?.notices[profileID] {
        Text(notice).font(.callout).foregroundStyle(.secondary)
          .accessibilityLabel(PanelsL10n.format("Download notice: %@", .string(notice)))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .quickLookPreview($quickLookURL)
    .onAppear { searchIsFocused = true }
    .onChange(of: currentProfileID) { _, _ in thumbnails.clear() }
  }

  private var filtersAreActive: Bool {
    !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (!mediaOnly && typeFilter != .all)
  }

  private var emptyTitle: String {
    PanelsL10n.string(mediaOnly ? "No downloaded media" : "No downloads")
  }

  private var emptyDescription: String {
    PanelsL10n.string(
      mediaOnly
        ? "Downloaded images, videos, and PDFs appear here."
        : "Downloads for this profile appear here.")
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
    .accessibilityLabel(PanelsL10n.string("Chronological downloads"))
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
              .accessibilityLabel(DownloadAccessibility.progressLabel(filename: item.filename))
              .accessibilityAddTraits(Self.downloadProgressAccessibilityTraits)
          } else {
            ProgressView().controlSize(.small)
              .accessibilityLabel(DownloadAccessibility.progressLabel(filename: item.filename))
              .accessibilityAddTraits(Self.downloadProgressAccessibilityTraits)
          }
          Text(byteStatus(item)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        if item.dangerous {
          Text(PanelsL10n.string("Blocked by the browser. This file cannot be opened here."))
            .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        if item.canOpen {
          Button(PanelsL10n.string("Quick Look")) { preview(item) }
            .disabled(!canUseFileActions)
          Button(PanelsL10n.string("Show in Finder")) { open(item, inFinder: true) }.disabled(
            !canUseFileActions)
          Button(PanelsL10n.string("Open")) { open(item, inFinder: false) }.disabled(
            !canUseFileActions)
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
      .focused($focusedActionsID, equals: item.id)
      .opacity(
        Self.actionsAreVisible(itemID: item.id, hoveredID: hoveredID, focusedID: focusedActionsID)
          ? 1 : 0)
      .accessibilityLabel(PanelsL10n.format("Actions for %@", .string(item.filename)))
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

  static func actionsAreVisible(itemID: String, hoveredID: String?, focusedID: String?) -> Bool {
    hoveredID == itemID || focusedID == itemID
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

  private func preview(_ item: BrowserDownload) {
    guard canUseFileActions, let downloads,
      let url = LibraryDownloadQuery.quickLookURL(
        for: item, profileID: profileID, currentProfileID: currentProfileID,
        downloads: downloads)
    else { return }
    quickLookURL = url
  }

  private func dragProvider(_ item: BrowserDownload) -> NSItemProvider {
    guard canUseDownloadActions,
      let url = downloads?.fileForDrag(
        id: item.id, profileID: profileID, selectedProfileID: currentProfileID)
    else { return NSItemProvider() }
    return NSItemProvider(contentsOf: url) ?? NSItemProvider()
  }

  private func subtitle(_ item: BrowserDownload) -> String {
    Self.subtitle(kind: fileType(item), source: item.source, language: .currentLaunchLanguage)
  }

  static func subtitle(kind: String, source: String, language: BrowserLanguage) -> String {
    let genericSources = ["Download", "Generated file", "Extension"]
    if genericSources.contains(where: {
      source == $0 || source == BrowserLocalization.string($0, language: language)
    }) {
      return kind
    }
    return BrowserLocalization.format(
      "%@ from %@", table: "Panels", language: language,
      arguments: [.string(kind), .string(source)])
  }

  private func mediaGrid(_ items: [LibraryMediaDownload]) -> some View {
    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    return ScrollView {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
        ForEach(items) { result in
          if let downloads {
            mediaCard(result.item, media: result.file, downloads: downloads)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityLabel(PanelsL10n.string("Downloaded media"))
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
    Self.fileType(for: item.fileURL, language: .currentLaunchLanguage)
  }

  static func fileType(for url: URL?, language: BrowserLanguage) -> String {
    let fallback = BrowserLocalization.string("File", table: "Panels", language: language)
    guard let url, let type = UTType(filenameExtension: url.pathExtension) else { return fallback }
    guard language.resolved == .hebrew else { return type.localizedDescription ?? fallback }

    let template: String
    if type.conforms(to: .image) {
      template = "%@ image"
    } else if type.conforms(to: .movie) || type.conforms(to: .video) {
      template = "%@ video"
    } else if type.conforms(to: .audio) {
      template = "%@ audio file"
    } else if type.conforms(to: .archive) {
      template = "%@ archive"
    } else if type.conforms(to: .content) {
      template = "%@ document"
    } else {
      template = "%@ file"
    }
    return BrowserLocalization.format(
      template, table: "Panels", language: language,
      arguments: [.string(url.pathExtension.uppercased())])
  }

  private func fileIcon(for item: BrowserDownload) -> NSImage {
    guard let url = item.fileURL,
      let type = UTType(filenameExtension: url.pathExtension.lowercased())
    else { return NSWorkspace.shared.icon(for: UTType.data) }
    return NSWorkspace.shared.icon(for: type)
  }

  private func byteStatus(_ item: BrowserDownload) -> String {
    let received = PanelsL10n.byteCount(item.receivedBytes)
    guard let total = item.totalBytes else { return received }
    return PanelsL10n.format(
      "%@ of %@", .string(received),
      .string(PanelsL10n.byteCount(total)))
  }

  private func actionLabel(_ action: DownloadAction) -> String {
    switch action {
    case .pause: PanelsL10n.string("Pause")
    case .resume: PanelsL10n.string("Resume")
    case .cancel: PanelsL10n.string("Cancel download")
    case .remove: PanelsL10n.string("Remove from list")
    }
  }
}

@MainActor @Observable
final class LibraryThumbnailLoader {
  private var images: [String: NSImage] = [:]
  private var cacheOrder: [String] = []
  private var active: Set<String> = []
  private let maximumConcurrentRequests = 3
  private let maximumCachedImages = 64
  private let makeRequest: (QLThumbnailGenerator.Request) -> LibraryThumbnailRequest

  init(
    makeRequest: @escaping (QLThumbnailGenerator.Request) -> LibraryThumbnailRequest = {
      LibraryThumbnailRequest($0)
    }
  ) {
    self.makeRequest = makeRequest
  }

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
      let result = await makeRequest(request).generate()?.representation,
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

  private func key(_ item: BrowserDownload, media: LibraryMediaFile, profileID: UUID) -> String {
    "\(profileID.uuidString):\(item.id):\(media.url.path)"
  }
}
