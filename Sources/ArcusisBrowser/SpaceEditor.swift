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
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "square.stack.3d.up")
          .font(.system(size: 26, weight: .light))
          .foregroundStyle(appearanceColor)
        VStack(alignment: .leading, spacing: 4) {
          Text(route.spaceID == nil ? "Make a little space" : "Your space")
            .font(.title2.weight(.semibold))
          Text("A place for a different part of your day.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        TextField("Name", text: $name)
          .focused($nameIsFocused)
          .onSubmit { submit() }
        Picker(
          "Color",
          selection: Binding(
            get: { appearance.tint },
            set: {
              appearance.selectPreset($0)
            })
        ) {
          ForEach(SpaceTint.allCases, id: \.self) { color in
            Label {
              Text(color.rawValue.capitalized)
            } icon: {
              Image(systemName: "circle.fill").foregroundStyle(color.color)
            }
            .tag(color)
          }
        }
        ColorPicker(
          "Custom color",
          selection: Binding(
            get: { appearanceColor },
            set: { updateCustomColor($0) }), supportsOpacity: false)
        TextField(
          "Hex RGB",
          text: Binding(
            get: { appearance.hexValue },
            set: { appearance.setHexDraft($0) })
        )
        .accessibilityLabel("Exact RGB hex color")
        .accessibilityHint(
          appearance.canSubmit
            ? "Enter six hexadecimal digits." : "Enter a valid six-digit RGB color to enable Save."
        )
        .overlay(alignment: .trailing) {
          if !appearance.canSubmit {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
          }
        }
        LabeledContent("Preview") {
          RoundedRectangle(cornerRadius: 8)
            .fill(appearanceColor)
            .frame(width: 72, height: 24)
            .accessibilityLabel("Space color preview \(appearance.color.hex)")
        }
        if route.spaceID == nil {
          Picker("Profile", selection: $sharedProfileID) {
            Text("New, separate profile").tag(Optional<UUID>.none)
            ForEach(store.session.profiles) { profile in
              Text("Share \(profile.name)").tag(Optional(profile.id))
            }
          }
        } else if let profileName {
          LabeledContent("Profile", value: profileName)
        }
      }
      Text(profileExplanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      HStack {
        if route.spaceID != nil {
          Button("Delete space…", role: .destructive) { deleteIsPresented = true }
            .disabled(store.session.spaces.count == 1)
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button(route.spaceID == nil ? "Create space" : "Save") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(SpaceEditorSavePolicy.isDisabled(name: name, appearance: appearance))
      }
    }
    .padding(28)
    .frame(width: horizontalSizeClass == .compact ? 380 : 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { nameIsFocused = true }
    .confirmationDialog("Delete \(name)?", isPresented: $deleteIsPresented) {
      Button("Delete space", role: .destructive) {
        if let id = route.spaceID, store.removeSpace(id) { dismiss() }
      }
    } message: {
      Text(route.spaceID.map { store.spaceRemovalImpact($0).message } ?? "")
    }
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
          "Changes apply to this Space in all \(impact.windows) windows. Deleting it closes \(impact.tabDescription); its profile is kept."
      }
      return "Renaming or changing this space’s color keeps its profile and tabs."
    }
    return sharedProfileID == nil
      ? "Choose a separate profile for a different account."
      : "Spaces sharing a profile use the same website sign-ins and extensions."
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
      error = "This space could not be saved. Check its name and profile."
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
