// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

struct ProfileDeletionConfirmation: View {
  static let headingTraits: AccessibilityTraits = .isHeader
  let profile: BrowserSettingsProfile
  let profiles: [BrowserSettingsProfile]
  let onDeleteProfile: (UUID, UUID?) async throws -> Void
  let onDismiss: () -> Void
  @State private var destinationID: UUID?
  @State private var removeSpaces: Bool
  @State private var deleting = false
  @State private var deletionFailure: String?

  init(
    profile: BrowserSettingsProfile, profiles: [BrowserSettingsProfile], removeSpaces: Bool = false,
    onDeleteProfile: @escaping (UUID, UUID?) async throws -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.profile = profile
    self.profiles = profiles
    self.onDeleteProfile = onDeleteProfile
    self.onDismiss = onDismiss
    _destinationID = State(
      initialValue: Self.initialDestinationID(for: profile.id, in: profiles))
    _removeSpaces = State(initialValue: removeSpaces)
  }

  static func initialDestinationID(
    for profileID: UUID, in profiles: [BrowserSettingsProfile]
  ) -> UUID? {
    profiles.first(where: { $0.id != profileID })?.id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(SettingsL10n.format("Delete %@?", .string(profile.name))).font(.headline)
        .accessibilityAddTraits(Self.headingTraits)
      Text(
        SettingsL10n.string(
          "Favorites and profile preferences will be removed. Chromium will schedule deletion of cookies, site data, history, cache and extensions. This cannot be undone."
        ))
      Picker(SettingsL10n.string("Spaces"), selection: $removeSpaces) {
        Text(SettingsL10n.string("Move Spaces")).tag(false)
        Text(SettingsL10n.string("Remove Spaces and close their tabs")).tag(true)
      }
      .disabled(deleting)
      if removeSpaces {
        Text(SettingsL10n.string("All Spaces using this profile and their tabs will be removed."))
        Text(
          SettingsL10n.string(
            "If no Spaces remain, an empty Space is created for a remaining profile."))
      } else {
        Picker(SettingsL10n.string("Move Spaces to"), selection: $destinationID) {
          ForEach(profiles.filter { $0.id != profile.id }) { candidate in
            Text(candidate.name).tag(Optional(candidate.id))
          }
        }
        .disabled(deleting)
      }
      if let deletionFailure { Text(deletionFailure).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button(SettingsL10n.string("Cancel"), role: .cancel) { onDismiss() }.disabled(deleting)
        Button(SettingsL10n.string(deleting ? "Deleting…" : "Delete"), role: .destructive) {
          let destination = removeSpaces ? nil : destinationID
          deleting = true
          deletionFailure = nil
          Task {
            do {
              try await onDeleteProfile(profile.id, destination)
              onDismiss()
            } catch {
              deletionFailure = SettingsL10n.string("Could not delete the profile. Try again.")
            }
            deleting = false
          }
        }.disabled(deleting || (!removeSpaces && destinationID == nil))
      }
    }.padding(24).frame(width: 420)
      .interactiveDismissDisabled(deleting)
  }
}
