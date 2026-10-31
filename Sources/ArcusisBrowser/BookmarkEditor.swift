// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct BookmarkEditor: View {
  let store: BrowserStore
  let route: BookmarkEditorRoute
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var address: String
  @State private var parentID: UUID?
  @State private var error: String?
  @State private var removing = false
  @FocusState private var nameIsFocused: Bool

  init(store: BrowserStore, route: BookmarkEditorRoute) {
    self.store = store
    self.route = route
    let item = store.library.bookmarks[route.profileID]?.items.first { $0.id == route.itemID }
    switch route.mode {
    case .newBookmark(_, let title, let address):
      _title = State(initialValue: title)
      _address = State(initialValue: address)
    case .newFolder:
      _title = State(initialValue: "")
      _address = State(initialValue: "")
    case .edit:
      _title = State(initialValue: item?.title ?? "")
      _address = State(initialValue: item?.address ?? "")
    }
    _parentID = State(initialValue: route.parentID ?? item?.parentID)
  }

  private var tree: BookmarkTree? { store.library.bookmarks[route.profileID] }
  private var item: BrowserBookmark? { tree?.items.first { $0.id == route.itemID } }
  private var isFolder: Bool {
    if case .newFolder = route.mode { return true }
    return item?.isFolder == true
  }
  private var heading: String {
    guard route.itemID == nil else { return "Edit bookmark" }
    return isFolder ? "New bookmark folder" : "Add bookmark"
  }
  private var busy: Bool {
    store.library.mutating.contains(LibraryKey(profileID: route.profileID, section: .bookmarks))
  }
  private var canSave: Bool {
    route.matches(store) && tree != nil
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (isFolder
        || LibraryAddress.destination(address.trimmingCharacters(in: .whitespacesAndNewlines))
          != nil)
      && !busy
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label(
        heading,
        systemImage: isFolder ? "folder" : "star"
      ).font(.title2.weight(.semibold))
      Text("\(store.profileName) profile").font(.callout).foregroundStyle(.secondary)
      TextField("Name", text: $title).textFieldStyle(.roundedBorder).focused($nameIsFocused)
        .onSubmit { submit() }
      if !isFolder {
        TextField("https://example.com", text: $address).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Bookmark address").onSubmit { submit() }
      }
      if let tree {
        if route.itemID == nil {
          Picker(
            "Folder", selection: Binding(get: { parentID ?? tree.otherID }, set: { parentID = $0 })
          ) {
            ForEach(tree.items.filter(\.isFolder)) { folder in
              Text(folder.path).tag(folder.id)
            }
          }
        } else {
          LabeledContent(
            "Folder", value: tree.items.first { $0.id == item?.parentID }?.path ?? "Unavailable")
        }
      }
      if !route.matches(store) {
        Text("This bookmark context is no longer available.").foregroundStyle(.secondary)
      }
      if let message = error ?? store.library.notice(route.profileID, section: .bookmarks) {
        Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        if route.itemID != nil {
          Button("Delete…", role: .destructive) { removing = true }.disabled(
            busy || !route.matches(store))
        }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save") { submit() }.keyboardShortcut(.defaultAction).disabled(!canSave)
      }
    }
    .padding(28).frame(width: 460).background(Color(nsColor: .windowBackgroundColor))
    .onAppear { nameIsFocused = true }
    .confirmationDialog(
      isFolder ? "Delete this bookmark folder and its contents?" : "Delete this bookmark?",
      isPresented: $removing
    ) {
      Button("Delete", role: .destructive) {
        if let id = route.itemID { store.deleteBookmark(id, profileID: route.profileID) }
      }
    } message: {
      Text("Saved bookmarks are removed from this profile. Open pages stay open.")
    }
  }

  private func submit() {
    guard canSave else { return }
    error = nil
    if !store.saveBookmark(route, title: title, address: address, parentID: parentID) {
      error = "The bookmark could not be saved. Check its name, address, and folder."
    }
  }
}
