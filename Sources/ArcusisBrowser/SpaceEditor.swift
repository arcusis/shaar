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

struct SpaceEditor: View {
  let store: BrowserStore
  let route: SpaceEditorRoute
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var name: String
  @State private var appearance: SpaceAppearanceDraft
  @State private var sharedProfileID: UUID?
  @State private var deleteIsPresented = false
  @State private var error: String?
  @FocusState private var nameIsFocused: Bool

  init(store: BrowserStore, route: SpaceEditorRoute) {
    self.store = store
    self.route = route
    let space = store.session.spaces.first { $0.id == route.spaceID }
    _name = State(initialValue: space?.name ?? "")
    let appearance = SpaceAppearanceDraft(
      tint: space?.tint ?? .lavender, customRGB: space?.customRGB)
    _appearance = State(initialValue: appearance)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(route.spaceID == nil ? "Create Space" : "Edit Space")
        .font(.title2.weight(.semibold))

      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($nameIsFocused)
        .onSubmit { submit() }
        .accessibilityLabel("Space name")

      colorSection
      profileSection
      SpaceSidebarPreview(name: name, profileName: selectedProfileName, color: appearanceColor)

      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }

      HStack(spacing: 10) {
        if route.spaceID != nil {
          Button("Delete…", role: .destructive) { deleteIsPresented = true }
            .disabled(store.session.spaces.count == 1)
        }
        Spacer(minLength: 8)
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(route.spaceID == nil ? "Create" : "Save") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(SpaceEditorSavePolicy.isDisabled(name: name, appearance: appearance))
      }
    }
    .padding(20)
    .frame(width: horizontalSizeClass == .compact ? 380 : 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { nameIsFocused = true }
    .onDisappear {
      if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
    }
    .confirmationDialog("Delete \(name)?", isPresented: $deleteIsPresented) {
      Button("Delete space", role: .destructive) {
        if let id = route.spaceID, store.removeSpace(id) { dismiss() }
      }
    } message: {
      Text(route.spaceID.map { store.spaceRemovalImpact($0).message } ?? "")
    }
  }

  private var colorSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("Sidebar color")
        .font(.subheadline.weight(.medium))

      HStack(spacing: 12) {
        ForEach(SpaceTint.allCases, id: \.self) { tint in
          Button {
            appearance.selectPreset(tint)
          } label: {
            Circle()
              .fill(tint.color)
              .frame(width: 24, height: 24)
              .padding(3)
              .overlay {
                Circle().strokeBorder(
                  appearance.tint == tint && appearance.customRGB == nil
                    ? Color.primary : Color.clear,
                  lineWidth: 1.5)
              }
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(tint.rawValue.capitalized) sidebar color")
          .accessibilityAddTraits(
            appearance.tint == tint && appearance.customRGB == nil ? .isSelected : [])
        }

        Spacer(minLength: 0)

        ColorPicker(
          "Custom",
          selection: Binding(
            get: { appearanceColor },
            set: { updateCustomColor($0) }),
          supportsOpacity: false
        )
        .accessibilityLabel("Custom sidebar color")
      }
      .padding(.horizontal, 2)
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder private var profileSection: some View {
    if route.spaceID == nil {
      VStack(alignment: .leading, spacing: 6) {
        Picker("Profile", selection: $sharedProfileID) {
          Text("New profile").tag(Optional<UUID>.none)
          ForEach(store.session.profiles) { profile in
            Text(profile.name).tag(Optional(profile.id))
          }
        }
        Text(profileExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        LabeledContent("Profile", value: profileName ?? "Unavailable")
        Text(profileExplanation)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var selectedProfileName: String {
    if route.spaceID != nil { return profileName ?? "Profile" }
    guard let sharedProfileID else { return "New profile" }
    return store.session.profiles.first { $0.id == sharedProfileID }?.name ?? "Profile"
  }

  private var profileName: String? {
    guard let space = store.session.spaces.first(where: { $0.id == route.spaceID }) else {
      return nil
    }
    return store.session.profiles.first { $0.id == space.profileID }?.name
  }

  private var profileExplanation: String {
    if let id = route.spaceID {
      let impact = store.spaceRemovalImpact(id)
      if impact.windows > 1 {
        return
          "Applies in all \(impact.windows) windows. Deleting Space closes \(impact.tabDescription); Profile stays."
      }
      return "Spaces in one Profile share website sign-ins and extensions."
    }
    return sharedProfileID == nil
      ? "Separate Profile keeps sign-ins and extensions apart."
      : "Spaces sharing a Profile share website sign-ins and extensions."
  }

  private func submit() {
    guard !SpaceEditorSavePolicy.isDisabled(name: name, appearance: appearance) else { return }
    let succeeded: Bool
    if let id = route.spaceID {
      succeeded = store.updateSpace(
        id, name: name, tint: appearance.tint, customRGB: appearance.customRGB)
    } else {
      succeeded = store.createSpace(
        name: name, sharingProfile: sharedProfileID, tint: appearance.tint,
        customRGB: appearance.customRGB)
    }
    if succeeded {
      dismiss()
    } else {
      error = "This Space could not be saved. Check its name and Profile."
    }
  }

  private var appearanceColor: Color {
    let value = appearance.color
    return Color(
      .sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255,
      blue: Double(value.blue) / 255, opacity: 1)
  }

  private func updateCustomColor(_ value: Color) {
    guard let color = NSColor(value).usingColorSpace(.sRGB) else {
      appearance.rejectColorInput()
      return
    }
    _ = appearance.setCustomComponents(
      red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
  }
}

private struct SpaceSidebarPreview: View {
  let name: String
  let profileName: String
  let color: Color
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 9) {
        Text(profileName)
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 3, height: 16)
          Image(systemName: "square.stack.3d.up.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
          Text(name.isEmpty ? "Space name" : name)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        Label("Pinned tab", systemImage: "globe")
          .font(.system(size: 8))
          .foregroundStyle(.secondary)
          .padding(.leading, 8)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(9)
      .frame(width: 132, alignment: .topLeading)
      .background {
        LinearGradient(
          colors: [
            color.opacity(reduceTransparency ? 0.45 : 0.50), Color(nsColor: .windowBackgroundColor),
          ],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      }

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 4) {
          Circle().fill(.red.opacity(0.65))
          Circle().fill(.yellow.opacity(0.7))
          Circle().fill(.green.opacity(0.65))
        }
        .frame(width: 24, height: 5)
        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.13))
          .frame(height: 5)
        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.08))
          .frame(width: 68, height: 5)
        Spacer(minLength: 0)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(Color(nsColor: .textBackgroundColor))
      .accessibilityLabel("Neutral page area")
    }
    .frame(height: 92)
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "Preview: \(name.isEmpty ? "Space name" : name), \(profileName) profile, colored sidebar and neutral page"
    )
  }
}
