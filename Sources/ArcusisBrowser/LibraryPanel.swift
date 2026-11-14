// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

enum LibraryBookmarkAccessibility {
  static func folderState(
    collapsed: Bool, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.string(
      collapsed ? "Collapsed" : "Expanded", table: "Panels", language: language)
  }
}

enum LibraryPanelSearch {
  static func matches(_ text: String, query: String) -> Bool {
    query.isEmpty || text.localizedStandardContains(query)
  }

  static func bookmarkRows(
    items: [BrowserBookmark], collapsed: Set<UUID>, query: String
  ) -> [BrowserBookmark] {
    if !query.isEmpty {
      return items.filter {
        matches("\($0.title) \($0.address ?? "") \($0.path)", query: query)
      }
    }
    var hiddenDepth: Int?
    return items.filter { item in
      if let hidden = hiddenDepth, item.depth > hidden { return false }
      hiddenDepth = item.isFolder && collapsed.contains(item.id) ? item.depth : nil
      return true
    }
  }
}

enum LibraryPanelAccessibility {
  static func loadingLabel(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.string("Loading library", table: "Panels", language: language)
  }
}

struct LibraryPanelFilteredRows<Element> {
  private let values: [Element]

  init(makeValues: () -> [Element]) {
    values = makeValues()
  }

  var rows: [Element] { values }
  var isEmpty: Bool { values.isEmpty }
}

enum LibraryHistoryAccessibility {
  static func removeLabel(
    title: String, address: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Remove %@ at %@ from history", table: "Panels", language: language,
      arguments: [.string(title), .string(address)])
  }
}

enum LibraryPanelFooterAccessibility {
  static func footerProgressLabel(
    language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    PanelsL10n.string("Updating Library…", language: language)
  }
}

struct LibraryPanel: View {
  let store: BrowserStore
  let profileID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var section: LibrarySection
  @State private var query = ""
  @State private var collapsed: Set<UUID> = []
  @State private var removing: UUID?
  @State private var choosingImport = false
  @State private var importPreview: [BrowserImportItem] = []
  @State private var importSource: BrowserImportSource = .chrome
  @State private var importError: String?
  @State private var showingImportPreview = false

  init(store: BrowserStore, profileID: UUID, section: LibrarySection) {
    self.store = store
    self.profileID = profileID
    _section = State(initialValue: section)
  }

  private var key: LibraryKey { LibraryKey(profileID: profileID, section: section) }
  private var ownsContext: Bool { store.session.selectedSpace.profileID == profileID }
  private var busy: Bool { store.library.mutating.contains(key) }
  private var loading: Bool { store.library.loading.contains(key) }
  private var tree: BookmarkTree? { store.library.bookmarks[profileID] }
  private var bookmarks: [BrowserBookmark] {
    guard let tree else { return [] }
    return LibraryPanelSearch.bookmarkRows(items: tree.items, collapsed: collapsed, query: query)
  }
  private var searchLabel: String {
    PanelsL10n.string(section == .bookmarks ? "Search Bookmarks" : "Search History")
  }

  private var history: [BrowserHistoryEntry] {
    (store.library.history[profileID] ?? []).filter {
      LibraryPanelSearch.matches("\($0.title) \($0.address)", query: query)
    }
  }

  var body: some View {
    let visibleBookmarks = bookmarks
    let filteredBookmarks = LibraryPanelFilteredRows {
      section == .bookmarks ? visibleBookmarks : []
    }
    let filteredHistory = LibraryPanelFilteredRows {
      section == .history ? history : []
    }
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(section.title).font(.title2.weight(.semibold))
          if ownsContext {
            Text(PanelsL10n.format("%@ profile", .string(store.profileName)))
              .font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button(PanelsL10n.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Picker(PanelsL10n.string("Library"), selection: $section) {
        ForEach(LibrarySection.allCases, id: \.self) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
      TextField(searchLabel, text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel(searchLabel)
      if !ownsContext {
        ContentUnavailableView(
          PanelsL10n.string("Profile changed"), systemImage: "person.crop.circle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if loading
        && (section == .bookmarks ? tree == nil : store.library.history[profileID] == nil)
      {
        ProgressView()
          .accessibilityLabel(LibraryPanelAccessibility.loadingLabel())
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if section == .bookmarks {
              ForEach(filteredBookmarks.rows) { bookmarkRow($0) }
            } else {
              ForEach(filteredHistory.rows) { historyRow($0) }
            }
          }
          if section == .bookmarks ? filteredBookmarks.isEmpty : filteredHistory.isEmpty {
            ContentUnavailableView(
              PanelsL10n.string("No matches"), systemImage: section == .bookmarks ? "star" : "clock"
            )
            .frame(maxWidth: .infinity).padding(.vertical, 32)
          }
        }
      }
      if let notice = store.library.notice(profileID, section: section) {
        Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        if section == .bookmarks {
          Button(PanelsL10n.string("Add bookmark…")) { add(folder: false) }
          Button(PanelsL10n.string("New folder…")) { add(folder: true) }
        } else {
          Text(
            PanelsL10n.plural(
              "%d recent pages", count: store.library.history[profileID]?.count ?? 0)
          )
          .font(.caption).foregroundStyle(.secondary)
          if store.library.hasMoreHistory(profileID) {
            Button(PanelsL10n.string("Load more")) { store.library.loadMoreHistory(profileID) }
          }
        }
        Spacer()
        Menu {
          ForEach(BrowserImportSource.allCases) { source in
            Button {
              importSource = source
              choosingImport = true
            } label: {
              Text(verbatim: source.title)
            }
          }
        } label: {
          Label(PanelsL10n.string("Import…"), systemImage: "square.and.arrow.down")
        }
        if loading || busy {
          ProgressView().controlSize(.small)
            .accessibilityLabel(LibraryPanelFooterAccessibility.footerProgressLabel())
        }
        Button(PanelsL10n.string("Refresh")) { store.library.refresh(profileID, section: section) }
      }
      .disabled(!ownsContext || busy || loading)
    }
    .padding(24).frame(width: 600, height: 480)
    .background(Color(nsColor: .windowBackgroundColor))
    .fileImporter(
      isPresented: $choosingImport, allowedContentTypes: [.item, .folder]
    ) { result in
      Task {
        do {
          let url = try result.get()
          let access = url.startAccessingSecurityScopedResource()
          defer { if access { url.stopAccessingSecurityScopedResource() } }
          importPreview = try await BrowserImport.readOffMain(url, source: importSource).items
          importError = nil
          showingImportPreview = true
        } catch {
          importError = error.localizedDescription
          showingImportPreview = true
        }
      }
    }
    .sheet(
      isPresented: $showingImportPreview,
      onDismiss: {
        importPreview = []
        importError = nil
      }
    ) {
      importPreviewSheet
    }
    .onChange(of: section) { _, section in
      query = ""
      if ownsContext { store.library.refresh(profileID, section: section) }
    }
    .confirmationDialog(
      PanelsL10n.string(
        tree?.items.first(where: { $0.id == removing })?.isFolder == true
          ? "Delete bookmark folder and its contents?" : "Delete this bookmark?"),
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button(PanelsL10n.string("Delete"), role: .destructive) {
        if let id = removing { store.deleteBookmark(id, profileID: profileID) }
        removing = nil
      }
    } message: {
      Text(
        PanelsL10n.string("Saved bookmarks are removed from this profile. Open pages stay open."))
    }
  }

  private var importPreviewSheet: some View {
    BrowserImportPreviewView(
      items: importPreview, source: importSource, profileName: store.profileName,
      error: importError,
      canImport: Self.canImportPreview(
        items: importPreview, hasBookmarkTree: tree != nil, busy: busy, loading: loading),
      onCancel: { showingImportPreview = false }, onImport: applyImport)
  }

  static func canImportPreview(
    items: [BrowserImportItem], hasBookmarkTree: Bool, busy: Bool, loading: Bool
  ) -> Bool {
    !items.isEmpty && !busy && !loading
      && (hasBookmarkTree || !items.contains { $0.kind == .bookmark })
  }

  private func applyImport() {
    guard ownsContext,
      Self.canImportPreview(
        items: importPreview, hasBookmarkTree: tree != nil, busy: busy, loading: loading)
    else { return }
    store.library.importBrowserData(
      importPreview, profile: profileID, otherFolderID: tree?.otherID ?? UUID(),
      completion: { success in
        if success { showingImportPreview = false }
      })
  }

  private func bookmarkRow(_ item: BrowserBookmark) -> some View {
    Button {
      if item.isFolder {
        if !collapsed.insert(item.id).inserted { collapsed.remove(item.id) }
      } else {
        store.openBookmark(item.id, profileID: profileID)
      }
    } label: {
      HStack(spacing: 10) {
        Image(
          systemName: item.isFolder
            ? (collapsed.contains(item.id) ? "folder" : "folder.fill") : "star"
        )
        .foregroundStyle(.secondary).frame(width: 20)
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).font(.system(size: 13, weight: item.isFolder ? .semibold : .regular))
            .lineLimit(1)
          if let address = item.address {
            Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(
              .middle
            ).environment(\.layoutDirection, .leftToRight)
          }
        }
        Spacer()
      }
      .padding(.vertical, 10).padding(
        .leading, query.isEmpty ? CGFloat(min(item.depth, 12)) * 12 : 0
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(!ownsContext || busy)
    .help(
      !item.isFolder && item.destination == nil
        ? PanelsL10n.string("This address cannot be opened here. Use Edit to change it.")
        : item.path
    )
    .accessibilityValue(
      LibraryBookmarkAccessibility.folderState(collapsed: collapsed.contains(item.id)),
      isEnabled: item.isFolder
    )
    .contextMenu {
      if item.isFolder {
        Button(PanelsL10n.string("New folder inside…")) { add(folder: true, parent: item.id) }
        Button(PanelsL10n.string("Add bookmark here…")) { add(folder: false, parent: item.id) }
      }
      if !item.isPermanent {
        Button(PanelsL10n.string("Edit…")) {
          store.showBookmarkEditor(BookmarkEditorRoute(profileID: profileID, mode: .edit(item.id)))
        }
        Menu(PanelsL10n.string("Move to folder")) {
          if let tree {
            ForEach(tree.items.filter(\.isFolder)) { folder in
              Button {
                store.moveBookmark(item.id, profileID: profileID, to: folder.id)
              } label: {
                Text(folder.path).environment(\.layoutDirection, .leftToRight)
              }
              .disabled(item.parentID == folder.id || tree.contains(item.id, inPathTo: folder.id))
            }
          }
        }
        Button(PanelsL10n.string("Delete…"), role: .destructive) { removing = item.id }
      }
    }
  }

  private func historyRow(_ item: BrowserHistoryEntry) -> some View {
    HStack(spacing: 12) {
      Button {
        store.openHistoryEntry(item.address, profileID: profileID)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "clock").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Text(item.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              .environment(\.layoutDirection, .leftToRight)
              .truncationMode(.middle)
          }
          Spacer()
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(!ownsContext || busy || item.destination == nil)
      let dateStyle = Date.FormatStyle(
        date: .abbreviated, time: .shortened, locale: PanelsL10n.formattingLocale())
      Text(item.lastVisit.formatted(dateStyle))
        .font(.caption).foregroundStyle(.secondary)
      Button {
        store.deleteHistoryEntry(item.address, profileID: profileID)
      } label: {
        Image(systemName: "trash")
      }.buttonStyle(.borderless).help(PanelsL10n.string("Remove all visits to this address"))
        .accessibilityLabel(
          LibraryHistoryAccessibility.removeLabel(title: item.title, address: item.address)
        )
        .disabled(!ownsContext || busy)
    }.padding(.vertical, 10)
  }

  private func add(folder: Bool, parent: UUID? = nil) {
    let tab = store.session.selectedPage?.tab
    let mode: BookmarkEditorMode =
      folder
      ? .newFolder(parent: parent)
      : .newBookmark(
        parent: parent, title: tab?.title ?? "", address: tab?.url.absoluteString ?? "")
    store.showBookmarkEditor(BookmarkEditorRoute(profileID: profileID, mode: mode))
  }
}
