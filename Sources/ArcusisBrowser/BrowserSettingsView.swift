import AppKit
import BrowserCore
import SwiftUI

struct BrowserSettingsProfile: Identifiable {
  let id: UUID
  let name: String
  let color: ProfileColorChoice
  let spaces: [BrowserSettingsSpace]
  let extensionCount: Int
  let accounts: [ConnectedAccount]
  var spaceCount: Int { spaces.count }
  var spaceNames: [String] { spaces.map(\.name) }

  init(
    id: UUID, name: String, color: ProfileColorChoice = .none, spaces: [BrowserSettingsSpace],
    extensionCount: Int = 0, accounts: [ConnectedAccount] = []
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.spaces = spaces
    self.extensionCount = extensionCount
    self.accounts = accounts
  }

}

struct BrowserSettingsSpace: Identifiable {
  let id: UUID
  let name: String
  let symbol: String
}

struct BrowserSettingsChoice: Identifiable {
  let id: String
  let title: String
}

enum BrowserSettingsSection: String, CaseIterable, Identifiable {
  case general
  case appearance
  case privacy
  case profiles
  case shortcuts
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .privacy: "Privacy & Security"
    case .profiles: "Profiles"
    case .shortcuts: "Shortcuts"
    case .about: "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintbrush"
    case .privacy: "hand.raised"
    case .profiles: "person.crop.circle"
    case .shortcuts: "command"
    case .about: "info.circle"
    }
  }
}

struct BrowserSettingsView: View {
  let profiles: [BrowserSettingsProfile]
  let searchEngines: [BrowserSettingsChoice]
  @Binding var selectedProfileID: UUID?
  @AppStorage("externalLinksInMainWindow") private var externalLinksInMainWindow = false
  @AppStorage("settingsStartFresh") private var startFresh = false
  @AppStorage("settingsWarnBeforeQuit") private var warnBeforeQuit = false
  @AppStorage("settingsAppearance") private var appearance = "system"
  @State private var defaultStatus = false
  @State private var defaultError: String?
  @State private var historyMessage: String?
  @State private var clearingHistory = false
  @State private var confirmHistory = false
  @Binding var sidebarInitiallyVisible: Bool
  @Binding var selectedSearchEngine: String
  let storageNotice: String?
  let onAddProfile: () -> Void
  let onRenameProfile: (UUID, String) -> Bool
  let onSetProfileColor: (UUID, ProfileColorChoice) -> Bool
  let onDeleteProfile: (UUID, UUID) -> Bool
  let onOpenSpace: (UUID) -> Void
  let onConnectAccount: (UUID, AccountProvider) -> Void
  let onDisconnectAccount: (UUID, AccountProvider) -> Void
  let extensionManager: (UUID) -> ExtensionManagerModel?
  let onAddExtensions: (UUID) -> Void
  let clearHistory: ((UUID) async throws -> Void)?
  @State private var deletingProfile: BrowserSettingsProfile?
  @State private var destinationID: UUID?
  @State private var selectedSection: BrowserSettingsSection
  @State private var profileNameEdits: [UUID: String] = [:]

  init(
    profiles: [BrowserSettingsProfile], searchEngines: [BrowserSettingsChoice],
    selectedProfileID: Binding<UUID?>, sidebarInitiallyVisible: Binding<Bool>,
    selectedSearchEngine: Binding<String>, storageNotice: String? = nil,
    onAddProfile: @escaping () -> Void = {},
    onRenameProfile: @escaping (UUID, String) -> Bool = { _, _ in false },
    onSetProfileColor: @escaping (UUID, ProfileColorChoice) -> Bool = { _, _ in false },
    onDeleteProfile: @escaping (UUID, UUID) -> Bool = { _, _ in false },
    onOpenSpace: @escaping (UUID) -> Void = { _ in },
    onConnectAccount: @escaping (UUID, AccountProvider) -> Void = { _, _ in },
    onDisconnectAccount: @escaping (UUID, AccountProvider) -> Void = { _, _ in },
    extensionManager: @escaping (UUID) -> ExtensionManagerModel? = { _ in nil },
    onAddExtensions: @escaping (UUID) -> Void = { _ in },
    clearHistory: ((UUID) async throws -> Void)? = nil,
    initialSection: BrowserSettingsSection = .general
  ) {
    self.profiles = profiles
    self.searchEngines = searchEngines
    _selectedProfileID = selectedProfileID
    _sidebarInitiallyVisible = sidebarInitiallyVisible
    _selectedSearchEngine = selectedSearchEngine
    self.storageNotice = storageNotice
    self.onAddProfile = onAddProfile
    self.onRenameProfile = onRenameProfile
    self.onSetProfileColor = onSetProfileColor
    self.onDeleteProfile = onDeleteProfile
    self.onOpenSpace = onOpenSpace
    self.onConnectAccount = onConnectAccount
    self.onDisconnectAccount = onDisconnectAccount
    self.extensionManager = extensionManager
    self.onAddExtensions = onAddExtensions
    self.clearHistory = clearHistory
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
        case .appearance:
          appearanceContent
        case .privacy:
          privacyContent
        case .profiles:
          profilesContent
        case .shortcuts:
          SettingsShortcutsPane()
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
        Text(
          "Its Spaces will move to \(profiles.first(where: { $0.id == destinationID })?.name ?? "the selected profile"). Its favorites will be removed."
        )
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
  }

  private var categoryBar: some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(BrowserSettingsSection.allCases) { section in
        Button {
          selectedSection = section
        } label: {
          HStack(spacing: 8) {
            Image(systemName: section.symbol)
              .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
              .frame(width: 24, height: 24)
              .background(sectionColor(section), in: RoundedRectangle(cornerRadius: 6))
            Text(section.title).lineLimit(1)
          }
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
    .frame(width: 205)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .background(.regularMaterial)
  }

  private func sectionColor(_ section: BrowserSettingsSection) -> Color {
    switch section {
    case .general: .gray
    case .appearance: .blue
    case .privacy: .blue
    case .profiles: .purple
    case .shortcuts: .indigo
    case .about: .gray
    }
  }

  private var generalContent: some View {
    Form {
      Section("Startup") {
        Picker("On startup", selection: $startFresh) {
          Text("Restore windows and tabs").tag(false)
          Text("Start with a new tab").tag(true)
        }
        LabeledContent("Default browser") {
          HStack {
            Text(defaultStatus ? "Default" : "Not default").foregroundStyle(.secondary)
            Button("Make Default") { setDefaultBrowser() }.disabled(defaultStatus)
          }
        }
      }
      Section("Windows") {
        Picker("Links from other apps open in", selection: $externalLinksInMainWindow) {
          Text("Mini window").tag(false)
          Text("Main window").tag(true)
        }
        Toggle("Show sidebar in new windows", isOn: $sidebarInitiallyVisible)
        Toggle("Warn before quitting with Command-Q", isOn: $warnBeforeQuit)
      }
      if let defaultError { Section { Text(defaultError).foregroundStyle(.red) } }
      if let storageNotice { Section { Text(storageNotice).foregroundStyle(.secondary) } }
    }
    .formStyle(.grouped)
    .onAppear { refreshDefaultStatus() }
  }

  /// LaunchServices stores the default browser by bundle identifier, so compare that rather than
  /// the path; development builds can exist at several paths with the same identifier.
  private func refreshDefaultStatus() {
    let identifier = Bundle.main.bundleIdentifier
    defaultStatus = ["http", "https"].allSatisfy { scheme in
      guard let identifier, let url = URL(string: "\(scheme)://example.com"),
        let current = NSWorkspace.shared.urlForApplication(toOpen: url)
      else { return false }
      return Bundle(url: current)?.bundleIdentifier == identifier
    }
  }

  private func setDefaultBrowser() {
    Task {
      do {
        try await NSWorkspace.shared.setDefaultApplication(
          at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
        try await NSWorkspace.shared.setDefaultApplication(
          at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https")
        defaultError = nil
      } catch { defaultError = error.localizedDescription }
      refreshDefaultStatus()
    }
  }

  private var appearanceContent: some View {
    Form {
      Section {
        Picker("Theme", selection: $appearance) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
      } header: {
        Text("Appearance")
      } footer: {
        Text("System follows your Mac appearance.")
      }
    }
    .formStyle(.grouped)
    .onChange(of: appearance) { _, value in BrowserSettingsAppearance.apply(value) }
  }

  private var privacyContent: some View {
    Form {
      Section {
        Picker("Profile", selection: $selectedProfileID) {
          ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
        }
        LabeledContent("Clear all history") {
          Button(clearingHistory ? "Clearing…" : "Clear History…") { confirmHistory = true }
            .disabled(clearHistory == nil || selectedProfileID == nil || clearingHistory)
        }
        if let historyMessage { Text(historyMessage).foregroundStyle(.secondary) }
      } header: {
        Text("Browsing History")
      } footer: {
        Text("Removes history for the selected profile. Cookies and cached files are not removed.")
      }
      MacPermissionsSection()
    }.formStyle(.grouped)
      .confirmationDialog("Clear all history for this profile?", isPresented: $confirmHistory) {
        Button("Clear History", role: .destructive) {
          guard let id = selectedProfileID, let clearHistory else { return }
          clearingHistory = true
          Task {
            do {
              try await clearHistory(id)
              historyMessage = "History cleared."
            } catch { historyMessage = "Could not clear history: \(error.localizedDescription)" }
            clearingHistory = false
          }
        }
      }
  }

  private var aboutContent: some View {
    Form {
      Section(ProductIdentity.name) {
        Text(ProductIdentity.meaning)
        Text("© 2026 Arcusis. All rights reserved.")
        LabeledContent(
          "Version",
          value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown")
        LabeledContent(
          "Build",
          value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        )
      }
    }.formStyle(.grouped)
  }

  private var profilesContent: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Profiles").font(.headline)
          Spacer()
          Button(action: onAddProfile) {
            Image(systemName: "plus")
          }
          .accessibilityLabel("Add Profile")
          .accessibilityIdentifier("settings.addProfile")
        }
        ForEach(profiles) { profile in
          Button {
            selectedProfileID = profile.id
          } label: {
            HStack(spacing: 9) {
              ProfileBadge(color: profile.color.rgb)
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1)
                Text(spaceCountLabel(profile.spaces.count)).font(.caption).foregroundStyle(
                  .secondary)
              }
              Spacer(minLength: 0)
              if selectedProfileID == profile.id { Image(systemName: "checkmark").font(.caption) }
            }
            .padding(8)
            .background(
              selectedProfileID == profile.id ? Color.accentColor.opacity(0.14) : .clear,
              in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        Spacer()
      }
      .padding(14)
      .frame(width: 205)
      .frame(maxHeight: .infinity)
      .background(.regularMaterial)
      Divider()
      if let profile = profiles.first(where: { $0.id == selectedProfileID }) {
        profileDetails(profile)
      } else {
        ContentUnavailableView("No Profile Selected", systemImage: "person.crop.circle")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func profileDetails(_ profile: BrowserSettingsProfile) -> some View {
    return Form {
      Section("Profile") {
        HStack {
          TextField("Name", text: profileNameBinding(profile))
            .accessibilityIdentifier("settings.renameProfile")
            .onSubmit { saveProfileName(profile) }
          Button("Save") { saveProfileName(profile) }
            .disabled(profileNameEdits[profile.id] == nil)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Color")
          ProfileColorPicker(color: profileColorBinding(profile))
        }
        .accessibilityIdentifier("settings.profileColor")
        Picker("Search engine", selection: $selectedSearchEngine) {
          ForEach(searchEngines) { Text($0.title).tag($0.id) }
        }
      }
      Section("Spaces using this profile") {
        if profile.spaces.isEmpty {
          Text("No Spaces assigned").foregroundStyle(.secondary)
        } else {
          ForEach(profile.spaces) { space in
            HStack {
              Label(space.name, systemImage: space.symbol)
              Spacer()
              Button("Open") { onOpenSpace(space.id) }
            }
          }
        }
      }
      Section {
        ForEach(AccountProvider.allCases) { provider in
          if let account = profile.accounts.first(where: { $0.provider == provider }) {
            ConnectedAccountRow(account: account) { onDisconnectAccount(profile.id, provider) }
          } else {
            Button {
              onConnectAccount(profile.id, provider)
            } label: {
              HStack(spacing: 10) {
                if let logo = provider.logo {
                  Image(nsImage: logo).resizable().frame(width: 18, height: 18)
                }
                Text("Connect \(provider.title)")
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.connect.\(provider.rawValue)")
          }
        }
      } header: {
        Text("Accounts")
      } footer: {
        Text(
          "Sign in with the provider's own page. Gmail, Drive, Outlook, and Teams then open signed in for every Space using this profile."
        )
      }
      Section("Extensions") {
        ProfileExtensionsSection(
          model: extensionManager(profile.id),
          onAddExtensions: { onAddExtensions(profile.id) })
      }
      Section {
        Button("Delete Profile…", role: .destructive) {
          destinationID = profiles.first(where: { $0.id != profile.id })?.id
          deletingProfile = profile
        }
        .disabled(profiles.count < 2)
        .accessibilityIdentifier("settings.deleteProfile")
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func profileNameBinding(_ profile: BrowserSettingsProfile) -> Binding<String> {
    Binding(
      get: {
        profileNameEdits[profile.id] ?? profiles.first(where: { $0.id == profile.id })?.name
          ?? profile.name
      },
      set: { profileNameEdits[profile.id] = $0 })
  }

  private func profileColorBinding(_ profile: BrowserSettingsProfile) -> Binding<ProfileColorChoice>
  {
    Binding(
      get: { profiles.first(where: { $0.id == profile.id })?.color ?? profile.color },
      set: { _ = onSetProfileColor(profile.id, $0) })
  }

  private func saveProfileName(_ profile: BrowserSettingsProfile) {
    guard let name = profileNameEdits[profile.id],
      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else { return }
    if onRenameProfile(profile.id, name) { profileNameEdits[profile.id] = nil }
  }

  private func spaceCountLabel(_ count: Int) -> String {
    "\(count) \(count == 1 ? "Space" : "Spaces")"
  }

}

struct ConnectedAccountRow: View {
  let account: ConnectedAccount
  var disconnect: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      AsyncImage(url: account.photoURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        if let logo = account.provider.logo {
          Image(nsImage: logo).resizable().padding(5)
        }
      }
      .frame(width: 28, height: 28)
      .clipShape(Circle())
      VStack(alignment: .leading, spacing: 1) {
        Text(account.name ?? account.email).lineLimit(1)
        Text(account.name == nil ? account.provider.title : account.email)
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if let disconnect { Button("Disconnect", action: disconnect) }
    }
  }
}

/// Shows what macOS allows Shaar to use, refreshed whenever the app becomes active again.
private struct MacPermissionsSection: View {
  @State private var statuses: [MacPermission: MacPermissionStatus] = [:]

  var body: some View {
    Section {
      ForEach(MacPermission.allCases) { permission in
        LabeledContent {
          HStack(spacing: 10) {
            Text(statuses[permission]?.label ?? "Checking…").foregroundStyle(.secondary)
            if let url = permission.settingsURL {
              Button("Open Settings") { NSWorkspace.shared.open(url) }
            }
          }
        } label: {
          Label(permission.title, systemImage: permission.symbol)
        }
      }
    } header: {
      Text("macOS Permissions")
    } footer: {
      Text(
        "Websites can only use what macOS allows. If a site's request is blocked here, change it in System Settings."
      )
    }
    .task { await refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in Task { await refresh() } }
  }

  private func refresh() async {
    for permission in MacPermission.allCases {
      statuses[permission] = await MacPermissionStatusReader.status(of: permission)
    }
  }
}
