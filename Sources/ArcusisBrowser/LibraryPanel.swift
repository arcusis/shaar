// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct LibraryPanel: View {
  let store: BrowserStore
  let profileID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var section: LibrarySection
  @State private var query = ""
  @State private var collapsed: Set<UUID> = []
  @State private var removing: UUID?

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
    if !query.isEmpty {
      return tree.items.filter {
        "\($0.title) \($0.address ?? "") \($0.path)".localizedCaseInsensitiveContains(query)
      }
    }
    var hiddenDepth: Int?
    return tree.items.filter { item in
      if let hidden = hiddenDepth, item.depth > hidden { return false }
      hiddenDepth = item.isFolder && collapsed.contains(item.id) ? item.depth : nil
      return true
    }
  }
  private var history: [BrowserHistoryEntry] {
    (store.library.history[profileID] ?? []).filter {
      query.isEmpty || "\($0.title) \($0.address)".localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(section.title).font(.title2.weight(.semibold))
          if ownsContext {
            Text("\(store.profileName) profile").font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Picker("Library", selection: $section) {
        ForEach(LibrarySection.allCases, id: \.self) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
      TextField("Search \(section.rawValue)", text: $query).textFieldStyle(.roundedBorder)
      if !ownsContext {
        ContentUnavailableView("Profile changed", systemImage: "person.crop.circle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if loading
        && (section == .bookmarks ? tree == nil : store.library.history[profileID] == nil)
      {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if section == .bookmarks {
              ForEach(bookmarks) { bookmarkRow($0) }
            } else {
              ForEach(history) { historyRow($0) }
            }
          }
          if section == .bookmarks ? bookmarks.isEmpty : history.isEmpty {
            ContentUnavailableView(
              "No matches", systemImage: section == .bookmarks ? "star" : "clock"
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
          Button("Add bookmark…") { add(folder: false) }
          Button("New folder…") { add(folder: true) }
        } else {
          Text("\(store.library.history[profileID]?.count ?? 0) recent pages")
            .font(.caption).foregroundStyle(.secondary)
          if store.library.hasMoreHistory(profileID) {
            Button("Load more") { store.library.loadMoreHistory(profileID) }
          }
        }
        Spacer()
        if loading || busy { ProgressView().controlSize(.small) }
        Button("Refresh") { store.library.refresh(profileID, section: section) }
      }
      .disabled(!ownsContext || busy || loading)
    }
    .padding(24).frame(width: 600, height: 480)
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: section) { _, section in
      query = ""
      if ownsContext { store.library.refresh(profileID, section: section) }
    }
    .confirmationDialog(
      tree?.items.first(where: { $0.id == removing })?.isFolder == true
        ? "Delete bookmark folder and its contents?" : "Delete this bookmark?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let id = removing { store.deleteBookmark(id, profileID: profileID) }
        removing = nil
      }
    } message: {
      Text("Saved bookmarks are removed from this profile. Open pages stay open.")
    }
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
              .middle)
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
        ? "This address cannot be opened here. Use Edit to change it." : item.path
    )
    .contextMenu {
      if item.isFolder {
        Button("New folder inside…") { add(folder: true, parent: item.id) }
        Button("Add bookmark here…") { add(folder: false, parent: item.id) }
      }
      if !item.isPermanent {
        Button("Edit…") {
          store.showBookmarkEditor(BookmarkEditorRoute(profileID: profileID, mode: .edit(item.id)))
        }
        Menu("Move to folder") {
          if let tree {
            ForEach(tree.items.filter(\.isFolder)) { folder in
              Button(folder.path) {
                store.moveBookmark(item.id, profileID: profileID, to: folder.id)
              }
              .disabled(item.parentID == folder.id || tree.contains(item.id, inPathTo: folder.id))
            }
          }
        }
        Button("Delete…", role: .destructive) { removing = item.id }
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
              .truncationMode(.middle)
          }
          Spacer()
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(!ownsContext || busy || item.destination == nil)
      Text(item.lastVisit.formatted(date: .abbreviated, time: .shortened))
        .font(.caption).foregroundStyle(.secondary)
      Button {
        store.deleteHistoryEntry(item.address, profileID: profileID)
      } label: {
        Image(systemName: "trash")
      }.buttonStyle(.borderless).help("Remove all visits to this address")
        .accessibilityLabel("Remove \(item.title) from history").disabled(!ownsContext || busy)
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
