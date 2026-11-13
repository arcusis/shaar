// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

/// Shared Space actions for the library and sidebar.
struct SpaceMenuContent: View {
  let store: BrowserStore
  let space: BrowserSpace

  static func canDeleteSpace(spaceCount: Int) -> Bool { spaceCount > 1 }

  var body: some View {
    Button(ShellL10n.string("Change Space Icon…")) { edit(.icon) }
    Button(ShellL10n.string("Rename Space…")) { edit(.name) }
    Button(ShellL10n.string("Edit Theme Color…")) { edit(.theme) }
    Menu(ShellL10n.string("Set Profile")) {
      ForEach(store.session.profiles) { profile in
        Toggle(
          isOn: Binding(
            get: { profile.id == space.profileID },
            set: { selected in if selected { _ = store.setSpaceProfile(space.id, to: profile.id) } }
          )
        ) {
          let account = store.preferences.accounts(for: profile.id).first
          ProfileIdentityLabel(profile: profile, account: account)
        }
      }
      Divider()
      Button(ShellL10n.string("New Profile…")) { store.onNewProfile?(space.id) }
        .disabled(store.onNewProfile == nil)
    }
    Divider()
    Button(ShellL10n.string("New Folder")) {
      store.perform(.space(space.id))
      store.showFolderEditor(.create(spaceID: space.id, parentID: nil))
    }
    Divider()
    Button(ShellL10n.string("Delete Space"), role: .destructive) {
      store.spacePendingDeletion = space.id
    }
    .disabled(!Self.canDeleteSpace(spaceCount: store.session.spaces.count))
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

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        ShellL10n.format(
          "Delete %@?",
          arguments: [.string(space(store.spacePendingDeletion)?.name ?? ShellL10n.string("Space"))]
        ),
        isPresented: isPending(\.spacePendingDeletion),
        presenting: store.spacePendingDeletion
      ) { id in
        Button(ShellL10n.string("Delete Space"), role: .destructive) { _ = store.removeSpace(id) }
      } message: { id in
        Text(store.spaceRemovalImpact(id).message)
      }
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
