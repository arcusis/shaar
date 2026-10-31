import BrowserCore
import SwiftUI

/// Shared Space actions for the library and sidebar.
struct SpaceMenuContent: View {
  let store: BrowserStore
  let space: BrowserSpace

  var body: some View {
    Button("Change Space Icon…") { edit(.icon) }
    Button("Rename Space…") { edit(.name) }
    Button("Edit Theme Color…") { edit(.theme) }
    Menu("Set Profile") {
      ForEach(store.session.profiles) { profile in
        Button {
          _ = store.setSpaceProfile(space.id, to: profile.id)
        } label: {
          if profile.id == space.profileID {
            Label(profile.name, systemImage: "checkmark")
          } else {
            Text(profile.name)
          }
        }
      }
      Divider()
      Button("New Profile…") { store.spacePendingNewProfile = space.id }
    }
    Divider()
    Button("New Folder") {
      store.perform(.space(space.id))
      store.showFolderEditor(.create(spaceID: space.id, parentID: nil))
    }
    Divider()
    Button("Delete Space", role: .destructive) { store.spacePendingDeletion = space.id }
      .disabled(store.session.spaces.count <= 1)
  }

  private func edit(_ focus: SpaceEditorFocus) {
    store.spaceEditorFocus = focus
    store.spaceEditor = .edit(space.id)
  }
}

/// Dialogs the Space menu asks for. They live on the window because a menu discards its own
/// views, and any dialog attached to them, as soon as it closes.
struct SpaceMenuDialogs: ViewModifier {
  let store: BrowserStore
  @State private var profileName = ""

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Delete \(space(store.spacePendingDeletion)?.name ?? "Space")?",
        isPresented: isPending(\.spacePendingDeletion),
        presenting: store.spacePendingDeletion
      ) { id in
        Button("Delete Space", role: .destructive) { _ = store.removeSpace(id) }
      } message: { id in
        Text(store.spaceRemovalImpact(id).message)
      }
      .alert(
        "New Profile", isPresented: isPending(\.spacePendingNewProfile),
        presenting: store.spacePendingNewProfile
      ) { id in
        TextField("Profile name", text: $profileName)
        Button("Cancel", role: .cancel) {}
        Button("Create") { _ = store.createProfileAndAssign(id, name: profileName) }
      }
      .onChange(of: store.spacePendingNewProfile) { profileName = "" }
  }

  private func space(_ id: UUID?) -> BrowserSpace? {
    store.session.spaces.first { $0.id == id }
  }

  private func isPending(_ request: ReferenceWritableKeyPath<BrowserStore, UUID?>) -> Binding<Bool>
  {
    Binding(
      get: { store[keyPath: request] != nil },
      set: { if !$0 { store[keyPath: request] = nil } })
  }
}
