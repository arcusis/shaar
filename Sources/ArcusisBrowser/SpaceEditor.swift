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
  @State private var appearance: SpaceAppearanceDraft
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
      initialValue: SpaceAppearanceDraft(
        tint: space?.tint ?? .lavender, customRGB: space?.customRGB))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Button {
          iconIsPresented = true
        } label: {
          SpaceIcon(symbol: symbol).font(.system(size: 22, weight: .medium))
            .frame(width: 48, height: 48)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change Space Icon")
        .popover(isPresented: $iconIsPresented) { SpaceIconPicker(symbol: $symbol) }
        TextField("Space name", text: $name)
          .textFieldStyle(.plain).font(.title3.weight(.semibold))
          .focused($nameIsFocused).onSubmit { submit() }
          .accessibilityLabel("Space name")
      }
      SpaceThemePicker(appearance: $appearance, focusOnAppear: store.spaceEditorFocus == .theme)
      if route.spaceID == nil { profileSection }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack(spacing: 10) {
        if route.spaceID != nil {
          Button("Delete…", role: .destructive) { deleteIsPresented = true }
            .buttonStyle(.plain).foregroundStyle(.red)
            .disabled(store.session.spaces.count == 1)
        }
        Spacer(minLength: 8)
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(route.spaceID == nil ? "Create" : "Done") { submit() }
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
    .confirmationDialog("Delete \(name)?", isPresented: $deleteIsPresented) {
      Button("Delete space", role: .destructive) {
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
      Picker("Profile", selection: $sharedProfileID) {
        Text("New profile").tag(Optional<UUID>.none)
        ForEach(store.session.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
      }
      Text(
        sharedProfileID == nil
          ? "Separate Profile keeps sign-ins and extensions apart."
          : "Spaces sharing a Profile share website sign-ins and extensions."
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
      error = "This Space could not be saved. Check its name and Profile."
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
      error = "This Space could not be saved. Check its name and Profile."
    }
  }
}
