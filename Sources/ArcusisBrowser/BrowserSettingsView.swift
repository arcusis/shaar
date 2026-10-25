import AppKit
import SwiftUI

struct BrowserSettingsProfile: Identifiable {
  let id: UUID
  let name: String
  let spaceCount: Int
}

struct BrowserSettingsChoice: Identifiable {
  let id: String
  let title: String
}

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
  case general
  case profiles
  case shortcuts

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .profiles: "Profiles"
    case .shortcuts: "Shortcuts"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .profiles: "person.crop.circle"
    case .shortcuts: "command"
    }
  }
}

struct BrowserSettingsView: View {
  let profiles: [BrowserSettingsProfile]
  let searchEngines: [BrowserSettingsChoice]
  @Binding var selectedProfileID: UUID?
  @Binding var sidebarInitiallyVisible: Bool
  @Binding var selectedSearchEngine: String
  let storageNotice: String?
  let onCreateProfile: (String) -> UUID?
  let onRenameProfile: (UUID, String) -> Bool
  @State private var selectedSection: BrowserSettingsSection
  @State private var profileEditor: ProfileEditorTarget?

  private struct ProfileEditorTarget: Identifiable {
    let id = UUID()
    let profileID: UUID?
    let name: String
  }

  init(
    profiles: [BrowserSettingsProfile], searchEngines: [BrowserSettingsChoice],
    selectedProfileID: Binding<UUID?>, sidebarInitiallyVisible: Binding<Bool>,
    selectedSearchEngine: Binding<String>, storageNotice: String? = nil,
    onCreateProfile: @escaping (String) -> UUID? = { _ in nil },
    onRenameProfile: @escaping (UUID, String) -> Bool = { _, _ in false },
    initialSection: BrowserSettingsSection = .general
  ) {
    self.profiles = profiles
    self.searchEngines = searchEngines
    _selectedProfileID = selectedProfileID
    _sidebarInitiallyVisible = sidebarInitiallyVisible
    _selectedSearchEngine = selectedSearchEngine
    self.storageNotice = storageNotice
    self.onCreateProfile = onCreateProfile
    self.onRenameProfile = onRenameProfile
    _selectedSection = State(initialValue: initialSection)
  }

  var body: some View {
    VStack(spacing: 0) {
      categoryBar
      Divider()
      Group {
        switch selectedSection {
        case .general:
          generalContent
        case .profiles:
          profilesContent
        case .shortcuts:
          shortcutsContent
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 600, minHeight: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .foregroundStyle(.primary)
    .sheet(item: $profileEditor) { target in
      ProfileNameEditor(
        title: target.profileID == nil ? "New Profile" : "Rename Profile",
        initialName: target.name,
        onCancel: { profileEditor = nil },
        onSave: { name in
          let saved =
            target.profileID.map { onRenameProfile($0, name) } ?? (onCreateProfile(name) != nil)
          if saved { profileEditor = nil }
          return saved
        })
    }
  }

  private var categoryBar: some View {
    HStack(spacing: 8) {
      ForEach(BrowserSettingsSection.allCases) { section in
        Button {
          selectedSection = section
        } label: {
          VStack(spacing: 7) {
            Image(systemName: section.symbol)
              .font(.system(size: 18, weight: .regular))
              .frame(height: 21)
            Text(section.title)
              .font(.caption.weight(.medium))
              .lineLimit(1)
          }
          .frame(width: 70)
          .foregroundStyle(selectedSection == section ? Color.accentColor : Color.secondary)
          .contentShape(Rectangle())
          .padding(.vertical, 11)
          .background {
            if selectedSection == section {
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 9)
    .frame(maxWidth: 460)
    .frame(maxWidth: .infinity)
  }

  private var generalContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("General")
        .font(.title2.weight(.semibold))
      settingsGroup {
        HStack {
          Text("Show sidebar in new windows")
          Spacer(minLength: 12)
          Toggle("Show sidebar in new windows", isOn: $sidebarInitiallyVisible)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityHint("Sets whether newly opened windows show the sidebar.")
        }
      }
      if let storageNotice {
        Text(storageNotice)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: 680, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var profilesContent: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Profiles")
          .font(.headline)
          .padding(.horizontal, 10)
        if profiles.isEmpty {
          Text("No profiles")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
        } else {
          ScrollView {
            VStack(spacing: 3) {
              ForEach(profiles) { profile in
                Button {
                  selectedProfileID = profile.id
                } label: {
                  HStack(spacing: 9) {
                    Text(profile.name)
                      .font(.callout.weight(.medium))
                      .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(spaceCountLabel(profile.spaceCount))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  .padding(.horizontal, 9)
                  .padding(.vertical, 7)
                  .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                  .background {
                    if selectedProfileID == profile.id {
                      RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    }
                  }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedProfileID == profile.id ? .isSelected : [])
              }
            }
          }
        }
        Spacer(minLength: 0)
        Button("Add Profile") { profileEditor = ProfileEditorTarget(profileID: nil, name: "") }
          .accessibilityIdentifier("settings.addProfile")
          .padding(.horizontal, 10)
      }
      .padding(.horizontal, 14)
      .padding(.top, 20)
      .frame(width: 205)
      .frame(maxHeight: .infinity, alignment: .topLeading)
      .background(Color.primary.opacity(0.025))
      Divider()
      VStack(alignment: .leading, spacing: 0) {
        profileDetails.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if let storageNotice {
          Text(storageNotice).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).padding(16)
        }
      }
    }
  }

  @ViewBuilder private var profileDetails: some View {
    if let profile = profiles.first(where: { $0.id == selectedProfileID }) {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text(profile.name).font(.title2.weight(.semibold)).lineLimit(1)
          Spacer()
          Button("Rename") {
            profileEditor = ProfileEditorTarget(profileID: profile.id, name: profile.name)
          }
          .accessibilityIdentifier("settings.renameProfile")
        }
        settingsGroup {
          HStack(spacing: 12) {
            Text("Search engine")
              .font(.callout.weight(.medium))
            Spacer(minLength: 8)
            if searchEngines.isEmpty {
              Text("No search engines available")
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
              Picker("Search engine", selection: $selectedSearchEngine) {
                ForEach(searchEngines) { choice in
                  Text(choice.title).tag(choice.id)
                }
              }
              .labelsHidden()
              .accessibilityLabel("Search engine")
              .frame(width: 150)
            }
          }
        }
        Text("Profiles share data across their assigned Spaces.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(24)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("Profile unavailable")
          .font(.title2.weight(.semibold))
        Text(
          profiles.isEmpty
            ? "Add a profile to manage its search engine."
            : "Choose an available profile to manage its search engine."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var shortcutsContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Shortcuts")
        .font(.title2.weight(.semibold))
      settingsGroup {
        VStack(spacing: 0) {
          shortcutRow("New tab", symbol: "plus.square", keys: ["⌘", "T"])
          shortcutDivider
          shortcutRow("Search or enter address", symbol: "magnifyingglass", keys: ["⌘", "L"])
          shortcutDivider
          shortcutRow("Reload", symbol: "arrow.clockwise", keys: ["⌘", "R"])
          shortcutDivider
          shortcutRow("Close tab", symbol: "xmark", keys: ["⌘", "W"])
          shortcutDivider
          shortcutRow("Bookmark this page", symbol: "bookmark", keys: ["⌘", "D"])
          shortcutDivider
          shortcutRow("Downloads", symbol: "arrow.down.circle", keys: ["⇧", "⌘", "J"])
        }
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: 680, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var shortcutDivider: some View {
    Divider().padding(.leading, 34)
  }

  private func shortcutRow(_ title: String, symbol: String, keys: [String]) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(title).font(.callout)
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
          Text(key)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(keys.joined(separator: " "))
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
  }

  private func spaceCountLabel(_ count: Int) -> String {
    "\(count) \(count == 1 ? "Space" : "Spaces")"
  }
}
