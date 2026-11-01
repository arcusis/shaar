// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI

enum SpaceEditorRoute: Hashable, Identifiable {
  case create
  case edit(UUID)

  var id: Self { self }
  var spaceID: UUID? {
    if case .edit(let id) = self { return id }
    return nil
  }
}

enum SpaceEditorFocus: Hashable {
  case name
  case icon
  case theme
}

struct SpaceEditor: View {
  let store: BrowserStore
  let route: SpaceEditorRoute
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var symbol: String
  @State private var appearance: ThemeColorDraft
  @State private var sharedProfileID: UUID?
  @State private var deleteIsPresented = false
  @State private var iconIsPresented = false
  @State private var finished = false
  @State private var error: String?
  @FocusState private var nameIsFocused: Bool
  private let original: BrowserSpace?

  init(store: BrowserStore, route: SpaceEditorRoute) {
    self.store = store
    self.route = route
    let space = store.session.spaces.first { $0.id == route.spaceID }
    original = space
    _name = State(initialValue: space?.name ?? "")
    _symbol = State(initialValue: space?.symbol ?? "square.stack")
    _appearance = State(
      initialValue: ThemeColorDraft(
        tint: space?.tint ?? .lavender, customRGB: space?.customRGB))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        SymbolPickerButton(
          symbol: $symbol, isPresented: $iconIsPresented,
          accessibilityLabel: SettingsL10n.string("Change Space Icon"))
        TextField(SettingsL10n.string("Space name"), text: $name)
          .textFieldStyle(.plain).font(.title3.weight(.semibold))
          .focused($nameIsFocused).onSubmit { submit() }
          .accessibilityLabel(SettingsL10n.string("Space name"))
      }
      ThemeColorPicker(color: $appearance, focusOnAppear: store.spaceEditorFocus == .theme)
      if route.spaceID == nil { profileSection }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack(spacing: 10) {
        if route.spaceID != nil {
          Button(SettingsL10n.string("Delete…"), role: .destructive) { deleteIsPresented = true }
            .buttonStyle(.plain).foregroundStyle(.red)
            .disabled(store.session.spaces.count == 1)
        }
        Spacer(minLength: 8)
        Button(SettingsL10n.string("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(
          .cancelAction)
        Button(SettingsL10n.string(route.spaceID == nil ? "Create" : "Done")) { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(SpaceEditorSavePolicy.isDisabled(name: name, appearance: appearance))
      }
    }
    .padding(20).frame(width: 380)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .onAppear {
      nameIsFocused = store.spaceEditorFocus == .name
      iconIsPresented = store.spaceEditorFocus == .icon
    }
    .onChange(of: name) { _, _ in applyLive() }
    .onChange(of: appearance) { _, _ in applyLive() }
    .onChange(of: symbol) { _, _ in applyLive() }
    .onDisappear {
      if !finished, let original {
        _ = store.updateSpace(
          original.id, name: original.name, tint: original.tint, customRGB: original.customRGB,
          symbol: original.symbol)
      }
      store.spaceEditorFocus = .name
    }
    .confirmationDialog(
      SettingsL10n.format("Delete %@?", .string(name)), isPresented: $deleteIsPresented
    ) {
      Button(SettingsL10n.string("Delete space"), role: .destructive) {
        if let id = route.spaceID, store.removeSpace(id) {
          finished = true
          dismiss()
        }
      }
    } message: {
      Text(route.spaceID.map { store.spaceRemovalImpact($0).message } ?? "")
    }
  }

  private var profileSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker(SettingsL10n.string("Profile"), selection: $sharedProfileID) {
        Text(SettingsL10n.string("New profile")).tag(Optional<UUID>.none)
        ForEach(store.session.profiles) { profile in
          Label(profile.name, systemImage: profile.displaySymbol).tag(Optional(profile.id))
        }
      }
      Text(
        sharedProfileID == nil
          ? SettingsL10n.string("Separate Profile keeps sign-ins and extensions apart.")
          : SettingsL10n.string("Spaces sharing a Profile share website sign-ins and extensions.")
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func applyLive() {
    guard let id = route.spaceID,
      !SpaceEditorSavePolicy.isDisabled(name: name, appearance: appearance)
    else { return }
    if !store.updateSpace(
      id, name: name, tint: appearance.tint, customRGB: appearance.customRGB, symbol: symbol)
    {
      error = SettingsL10n.string("This Space could not be saved. Check its name and Profile.")
    } else {
      error = nil
    }
  }

  private func submit() {
    guard !SpaceEditorSavePolicy.isDisabled(name: name, appearance: appearance) else { return }
    let succeeded: Bool
    if let id = route.spaceID {
      succeeded = store.updateSpace(
        id, name: name, tint: appearance.tint, customRGB: appearance.customRGB, symbol: symbol)
    } else {
      succeeded = store.createSpace(
        name: name, sharingProfile: sharedProfileID, tint: appearance.tint,
        customRGB: appearance.customRGB, symbol: symbol)
    }
    if succeeded {
      finished = true
      dismiss()
    } else {
      error = SettingsL10n.string("This Space could not be saved. Check its name and Profile.")
    }
  }
}
