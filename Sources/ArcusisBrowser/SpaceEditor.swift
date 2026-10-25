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
  @State private var name: String
  @State private var tint: SpaceTint
  @State private var sharedProfileID: UUID?
  @State private var deleteIsPresented = false
  @State private var error: String?
  @FocusState private var nameIsFocused: Bool

  init(store: BrowserStore, route: SpaceEditorRoute) {
    self.store = store
    self.route = route
    let space = store.session.spaces.first { $0.id == route.spaceID }
    _name = State(initialValue: space?.name ?? "")
    _tint = State(initialValue: space?.tint ?? .lavender)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "square.stack.3d.up")
          .font(.system(size: 26, weight: .light))
          .foregroundStyle(tint.color)
        VStack(alignment: .leading, spacing: 4) {
          Text(route.spaceID == nil ? "Make a little space" : "Your space")
            .font(.title2.weight(.semibold))
          Text("A place for a different part of your day.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Form {
        TextField("Name", text: $name)
          .focused($nameIsFocused)
          .onSubmit { submit() }
        Picker("Color", selection: $tint) {
          ForEach(SpaceTint.allCases, id: \.self) { color in
            Label {
              Text(color.rawValue.capitalized)
            } icon: {
              Image(systemName: "circle.fill").foregroundStyle(color.color)
            }
            .tag(color)
          }
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
      .formStyle(.grouped)
      .frame(height: 155)
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
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(28)
    .frame(width: 440)
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
    let succeeded: Bool
    if let id = route.spaceID {
      succeeded = store.updateSpace(id, name: name, tint: tint)
    } else {
      succeeded = store.createSpace(name: name, sharingProfile: sharedProfileID, tint: tint)
    }
    if succeeded {
      dismiss()
    } else {
      error = "This space could not be saved. Check its name and profile."
    }
  }
}
