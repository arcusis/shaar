import BrowserCore
import SwiftUI

/// Shared Space actions for the library and sidebar.
struct SpaceMenuContent: View {
  let store: BrowserStore
  let space: BrowserSpace
  @State private var confirmingDelete = false
  @State private var creatingProfile = false
  @State private var profileName = ""

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
      Button("New Profile…") {
        profileName = ""
        creatingProfile = true
      }
    }
    .alert("New Profile", isPresented: $creatingProfile) {
      TextField("Profile name", text: $profileName)
      Button("Cancel", role: .cancel) {}
      Button("Create") { _ = store.createProfileAndAssign(space.id, name: profileName) }
    }
    Divider()
    Button("New Folder") {
      store.perform(.space(space.id))
      store.showFolderEditor(.create(spaceID: space.id, parentID: nil))
    }
    Divider()
    Button("Delete Space", role: .destructive) { confirmingDelete = true }
      .disabled(store.session.spaces.count <= 1)
      .confirmationDialog("Delete \(space.name)?", isPresented: $confirmingDelete) {
        Button("Delete Space", role: .destructive) { _ = store.removeSpace(space.id) }
      } message: {
        Text(store.spaceRemovalImpact(space.id).message)
      }
  }

  private func edit(_ focus: SpaceEditorFocus) {
    store.spaceEditorFocus = focus
    store.spaceEditor = .edit(space.id)
  }
}
