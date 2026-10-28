import AppKit
import SwiftUI

struct BrowserSettingsProfile: Identifiable {
  let id: UUID
  let name: String
  let spaceCount: Int
  var spaceNames: [String] = []
}

struct BrowserSettingsChoice: Identifiable {
  let id: String
  let title: String
}

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
  case general
  case search
  case profiles
  case shortcuts
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .search: "Search"
    case .profiles: "Profiles"
    case .shortcuts: "Shortcuts"
    case .about: "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .search: "magnifyingglass"
    case .profiles: "person.crop.circle"
    case .shortcuts: "command"
    case .about: "info.circle"
    }
  }
}

struct BrowserSettingsView: View {
  let profiles: [BrowserSettingsProfile]
  let searchEngines: [BrowserSettingsChoice]
  let nativeBitwardenController: NativeBitwardenController?
  @Binding var selectedProfileID: UUID?
  @AppStorage("externalLinksInMainWindow") private var externalLinksInMainWindow = false
  @Binding var sidebarInitiallyVisible: Bool
  @Binding var selectedSearchEngine: String
  let storageNotice: String?
  let onCreateProfile: (String) -> UUID?
  let onRenameProfile: (UUID, String) -> Bool
  let onDeleteProfile: (UUID, UUID) -> Bool
  @State private var deletingProfile: BrowserSettingsProfile?
  @State private var destinationID: UUID?
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
    onDeleteProfile: @escaping (UUID, UUID) -> Bool = { _, _ in false },
    nativeBitwardenController: NativeBitwardenController? = nil,
    initialSection: BrowserSettingsSection = .general
  ) {
    self.profiles = profiles
    self.searchEngines = searchEngines
    self.nativeBitwardenController = nativeBitwardenController
    _selectedProfileID = selectedProfileID
    _sidebarInitiallyVisible = sidebarInitiallyVisible
    _selectedSearchEngine = selectedSearchEngine
    self.storageNotice = storageNotice
    self.onCreateProfile = onCreateProfile
    self.onRenameProfile = onRenameProfile
    self.onDeleteProfile = onDeleteProfile
    _selectedSection = State(initialValue: initialSection)
  }

  var body: some View {
    HStack(spacing: 0) {
      categoryBar
      Divider()
      Group {
        switch selectedSection {
        case .general:
          generalContent
        case .search:
          searchContent
        case .profiles:
          profilesContent
        case .shortcuts:
          shortcutsContent
        case .about:
          aboutContent
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(minWidth: 600, minHeight: 440)
    .background(Color(nsColor: .windowBackgroundColor))
    .foregroundStyle(.primary)
    .sheet(item: $deletingProfile) { profile in
      VStack(alignment: .leading, spacing: 16) {
        Text("Delete \(profile.name)?").font(.headline)
        Text("Its Spaces move to the selected profile. Its favorites will be removed.")
        Picker("Move Spaces to", selection: $destinationID) {
          ForEach(profiles.filter { $0.id != profile.id }) { candidate in
            Text(candidate.name).tag(Optional(candidate.id))
          }
        }
        HStack {
          Spacer()
          Button("Cancel") { deletingProfile = nil }
          Button("Delete", role: .destructive) {
            if let destinationID, onDeleteProfile(profile.id, destinationID) {
              deletingProfile = nil
            }
          }.disabled(destinationID == nil)
        }
      }.padding(24).frame(width: 420)
    }
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
    VStack(alignment: .leading, spacing: 3) {
      ForEach(BrowserSettingsSection.allCases) { section in
        Button {
          selectedSection = section
        } label: {
          Label(section.title, systemImage: section.symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
              if selectedSection == section {
                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.18))
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
      }
      Spacer()
    }
    .padding(12)
    .frame(width: 155)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(.regularMaterial)
  }

  private var searchContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Search").font(.title2.weight(.semibold))
      Text("Search engine is configured per profile.").foregroundStyle(.secondary)
      ForEach(searchEngines) { engine in Text(engine.title) }
      Button("Open Profiles") { selectedSection = .profiles }
      Spacer()
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var aboutContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("About Arcusis Browser").font(.title2.weight(.semibold))
      Text(
        "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")"
      )
      Text(
        "Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown")"
      )
      Spacer()
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
      Toggle("Open external links in main window", isOn: $externalLinksInMainWindow)
        .toggleStyle(.switch)
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
      .padding(.bottom, 16)
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
          Button("Delete", role: .destructive) {
            destinationID = profiles.first(where: { $0.id != profile.id })?.id
            deletingProfile = profile
          }.disabled(profiles.count < 2)
            .accessibilityIdentifier("settings.deleteProfile")
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
        VStack(alignment: .leading, spacing: 6) {
          Text("Spaces").font(.callout.weight(.medium))
          if profile.spaceNames.isEmpty {
            Text("No Spaces assigned")
              .foregroundStyle(.secondary)
          } else {
            ForEach(Array(profile.spaceNames.enumerated()), id: \.offset) { _, name in
              Text(name).lineLimit(1)
            }
          }
        }
        .font(.callout)
        if let nativeBitwardenController {
          PasswordManagerSettingsView(controller: nativeBitwardenController)
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
