import BrowserCore
import SwiftUI

enum FolderEditorRoute: Hashable {
  case create(spaceID: UUID, parentID: UUID?)
  case edit(spaceID: UUID, folderID: UUID)

  var spaceID: UUID {
    switch self {
    case .create(let space, _), .edit(let space, _): space
    }
  }
  var folderID: UUID? {
    if case .edit(_, let folder) = self { return folder }
    return nil
  }
  func matches(_ session: BrowserSession) -> Bool {
    guard spaceID == session.selectedSpaceID else { return false }
    switch self {
    case .create(_, let parent):
      return parent == nil || session.selectedSpace.folders.contains { $0.id == parent }
    case .edit(_, let folder): return session.selectedSpace.folders.contains { $0.id == folder }
    }
  }
}

struct FolderEditor: View {
  let store: BrowserStore
  let route: FolderEditorRoute
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var error: String?
  @State private var removing = false
  @FocusState private var nameIsFocused: Bool

  init(store: BrowserStore, route: FolderEditorRoute) {
    self.store = store
    self.route = route
    _name = State(
      initialValue: store.session.spaces.first { $0.id == route.spaceID }?
        .folders.first { $0.id == route.folderID }?.name ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(route.folderID == nil ? "New Folder" : "Rename Folder", systemImage: "folder")
        .font(.headline)
      TextField("Folder name", text: $name).textFieldStyle(.roundedBorder)
        .focused($nameIsFocused).onSubmit { submit() }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        if route.folderID != nil {
          Button("Remove folder…", role: .destructive) { removing = true }
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button(route.folderID == nil ? "Create folder" : "Save") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !route.matches(store.session))
      }
    }
    .padding(20).frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
    .onAppear { nameIsFocused = true }
    .confirmationDialog("Remove \(name)?", isPresented: $removing) {
      Button("Remove folder", role: .destructive) {
        if let id = route.folderID, store.removeFolder(id, in: route.spaceID) { dismiss() }
      }
    } message: {
      Text("Tabs and nested folders move to its parent. Pages stay open.")
    }
  }

  private func submit() {
    guard route.matches(store.session) else { return }
    let succeeded: Bool
    switch route {
    case .create(let space, let parent):
      succeeded = store.createFolder(name: name, in: space, parentID: parent) != nil
    case .edit(let space, let folder): succeeded = store.renameFolder(folder, in: space, name: name)
    }
    if succeeded {
      dismiss()
    } else {
      error = "This folder could not be saved. Check its name and location."
    }
  }

}
