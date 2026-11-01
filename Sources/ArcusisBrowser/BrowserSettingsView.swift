// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

struct BrowserSettingsProfile: Identifiable {
  let id: UUID
  let name: String
  let color: ProfileColorChoice
  let symbol: String
  let spaces: [BrowserSettingsSpace]
  let accounts: [ConnectedAccount]
  var spaceCount: Int { spaces.count }
  var spaceNames: [String] { spaces.map(\.name) }

  init(
    id: UUID, name: String, color: ProfileColorChoice = .none,
    symbol: String = BrowserProfile.defaultSymbol, spaces: [BrowserSettingsSpace],
    accounts: [ConnectedAccount] = []
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.symbol = symbol
    self.spaces = spaces
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
    case .general: SettingsL10n.string("General")
    case .appearance: SettingsL10n.string("Appearance")
    case .privacy: SettingsL10n.string("Privacy & Security")
    case .profiles: SettingsL10n.string("Profiles")
    case .shortcuts: SettingsL10n.string("Shortcuts")
    case .about: SettingsL10n.string("About")
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
  @AppStorage(BrowserLanguage.selectionDefaultsKey) private var selectedLanguage =
    BrowserLanguage.systemDefault.rawValue
  private var languageSelection: Binding<String> {
    Binding(
      get: {
        BrowserLanguage(rawValue: selectedLanguage)?.rawValue
          ?? BrowserLanguage.systemDefault.rawValue
      },
      set: { rawValue in
        if let selection = BrowserLanguage(rawValue: rawValue) {
          selectedLanguage = selection.rawValue
        }
      })
  }
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
  let onSetProfileSymbol: (UUID, String) -> Bool
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
  @State private var profileSymbolPickerIsPresented = false

  init(
    profiles: [BrowserSettingsProfile], searchEngines: [BrowserSettingsChoice],
    selectedProfileID: Binding<UUID?>, sidebarInitiallyVisible: Binding<Bool>,
    selectedSearchEngine: Binding<String>, storageNotice: String? = nil,
    onAddProfile: @escaping () -> Void = {},
    onRenameProfile: @escaping (UUID, String) -> Bool = { _, _ in false },
    onSetProfileColor: @escaping (UUID, ProfileColorChoice) -> Bool = { _, _ in false },
    onSetProfileSymbol: @escaping (UUID, String) -> Bool = { _, _ in false },
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
    self.onSetProfileSymbol = onSetProfileSymbol
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
        Text(SettingsL10n.format("Delete %@?", .string(profile.name))).font(.headline)
        Text(
          SettingsL10n.format(
            "Its Spaces will move to %@. Its favorites will be removed.",
            .string(
              profiles.first(where: { $0.id == destinationID })?.name
                ?? SettingsL10n.string("the selected profile"))))
        Picker(SettingsL10n.string("Move Spaces to"), selection: $destinationID) {
          ForEach(profiles.filter { $0.id != profile.id }) { candidate in
            Text(candidate.name).tag(Optional(candidate.id))
          }
        }
        HStack {
          Spacer()
          Button(SettingsL10n.string("Cancel")) { deletingProfile = nil }
          Button(SettingsL10n.string("Delete"), role: .destructive) {
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
      Section(SettingsL10n.string("Startup")) {
        Picker(SettingsL10n.string("On startup"), selection: $startFresh) {
          Text(SettingsL10n.string("Restore windows and tabs")).tag(false)
          Text(SettingsL10n.string("Start with a new tab")).tag(true)
        }
        LabeledContent(SettingsL10n.string("Default browser")) {
          HStack {
            Text(SettingsL10n.string(defaultStatus ? "Default" : "Not default")).foregroundStyle(
              .secondary)
            Button(SettingsL10n.string("Make Default")) { setDefaultBrowser() }.disabled(
              defaultStatus)
          }
        }
      }
      Section(SettingsL10n.string("Windows")) {
        Picker(
          SettingsL10n.string("Links from other apps open in"),
          selection: $externalLinksInMainWindow
        ) {
          Text(SettingsL10n.string("Mini window")).tag(false)
          Text(SettingsL10n.string("Main window")).tag(true)
        }
        Toggle(SettingsL10n.string("Show sidebar in new windows"), isOn: $sidebarInitiallyVisible)
        Toggle(SettingsL10n.string("Warn before quitting with Command-Q"), isOn: $warnBeforeQuit)
      }
      Section {
        Picker(SettingsL10n.string("Language"), selection: languageSelection) {
          Text(SettingsL10n.string("System Default")).tag(BrowserLanguage.systemDefault.rawValue)
          Text("English").tag(BrowserLanguage.english.rawValue)
          Text("עברית").tag(BrowserLanguage.hebrew.rawValue)
        }
        Text(SettingsL10n.string("Language changes after you restart the app."))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let defaultError { Section { Text(defaultError).foregroundStyle(.red) } }
      if let storageNotice {
        Section { Text(SettingsL10n.notice(storageNotice)).foregroundStyle(.secondary) }
      }
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
        Picker(SettingsL10n.string("Theme"), selection: $appearance) {
          Text(SettingsL10n.string("System")).tag("system")
          Text(SettingsL10n.string("Light")).tag("light")
          Text(SettingsL10n.string("Dark")).tag("dark")
        }
      } header: {
        Text(SettingsL10n.string("Appearance"))
      } footer: {
        Text(SettingsL10n.string("System follows your Mac appearance."))
      }
    }
    .formStyle(.grouped)
    .onChange(of: appearance) { _, value in BrowserSettingsAppearance.apply(value) }
  }

  private var privacyContent: some View {
    Form {
      Section {
        Picker(SettingsL10n.string("Profile"), selection: $selectedProfileID) {
          ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
        }
        LabeledContent(SettingsL10n.string("Clear all history")) {
          Button(SettingsL10n.string(clearingHistory ? "Clearing…" : "Clear History…")) {
            confirmHistory = true
          }
          .disabled(clearHistory == nil || selectedProfileID == nil || clearingHistory)
        }
        if let historyMessage { Text(historyMessage).foregroundStyle(.secondary) }
      } header: {
        Text(SettingsL10n.string("Browsing History"))
      } footer: {
        Text(
          SettingsL10n.string(
            "Removes history for the selected profile. Cookies and cached files are not removed."))
      }
      MacPermissionsSection()
    }.formStyle(.grouped)
      .confirmationDialog(
        SettingsL10n.string("Clear all history for this profile?"), isPresented: $confirmHistory
      ) {
        Button(SettingsL10n.string("Clear History"), role: .destructive) {
          guard let id = selectedProfileID, let clearHistory else { return }
          clearingHistory = true
          Task {
            do {
              try await clearHistory(id)
              historyMessage = SettingsL10n.string("History cleared.")
            } catch {
              historyMessage = SettingsL10n.format(
                "Could not clear history: %@", .string(error.localizedDescription))
            }
            clearingHistory = false
          }
        }
      }
  }

  private var aboutContent: some View {
    Form {
      Section(ProductIdentity.name) {
        Text(ProductIdentity.meaning)
        Text(SettingsL10n.string("© 2026 Arcusis. All rights reserved."))
        LabeledContent(
          SettingsL10n.string("Version"),
          value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? SettingsL10n.string("Unknown"))
        LabeledContent(
          SettingsL10n.string("Build"),
          value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? SettingsL10n.string("Unknown")
        )
      }
    }.formStyle(.grouped)
  }

  private var profilesContent: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(SettingsL10n.string("Profiles")).font(.headline)
          Spacer()
          Button(action: onAddProfile) {
            Image(systemName: "plus")
          }
          .accessibilityLabel(SettingsL10n.string("Add Profile"))
          .accessibilityIdentifier("settings.addProfile")
        }
        ForEach(profiles) { profile in
          Button {
            selectedProfileID = profile.id
          } label: {
            HStack(spacing: 9) {
              ProfileBadge(color: profile.color.rgb, symbol: profile.symbol)
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
        ContentUnavailableView(
          SettingsL10n.string("No Profile Selected"), systemImage: "person.crop.circle"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func profileDetails(_ profile: BrowserSettingsProfile) -> some View {
    return Form {
      Section(SettingsL10n.string("Profile")) {
        HStack(spacing: 12) {
          SymbolPickerButton(
            symbol: profileSymbolBinding(profile), isPresented: $profileSymbolPickerIsPresented,
            accessibilityLabel: SettingsL10n.string("Change Profile Icon"))
          TextField(SettingsL10n.string("Name"), text: profileNameBinding(profile))
            .accessibilityIdentifier("settings.renameProfile")
            .onSubmit { saveProfileName(profile) }
          Button(SettingsL10n.string("Save")) { saveProfileName(profile) }
            .disabled(profileNameEdits[profile.id] == nil)
        }
        ProfileColorPicker(color: profileColorBinding(profile))
          .accessibilityIdentifier("settings.profileColor")
        Picker(SettingsL10n.string("Search engine"), selection: $selectedSearchEngine) {
          ForEach(searchEngines) { Text($0.title).tag($0.id) }
        }
      }
      Section(SettingsL10n.string("Spaces using this profile")) {
        if profile.spaces.isEmpty {
          Text(SettingsL10n.string("No Spaces assigned")).foregroundStyle(.secondary)
        } else {
          ForEach(profile.spaces) { space in
            HStack {
              Label(space.name, systemImage: space.symbol)
              Spacer()
              Button(SettingsL10n.string("Open")) { onOpenSpace(space.id) }
            }
          }
        }
      }
      Section {
        ForEach(profile.accounts, id: \.provider) { account in
          ConnectedAccountRow(account: account) {
            onDisconnectAccount(profile.id, account.provider)
          }
        }
        ForEach(AccountProvider.connectable(alongside: profile.accounts)) { provider in
          Button {
            onConnectAccount(profile.id, provider)
          } label: {
            HStack(spacing: 10) {
              if let logo = provider.logo {
                Image(nsImage: logo).resizable().frame(width: 18, height: 18)
              }
              Text(SettingsL10n.format("Connect %@", .string(provider.title)))
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("settings.connect.\(provider.rawValue)")
        }
      } header: {
        Text(SettingsL10n.string("Accounts"))
      } footer: {
        Text(
          SettingsL10n.string(
            "Sign in with the provider's own page. Gmail, Drive, Outlook, and Teams then open signed in for every Space using this profile."
          ))
      }
      Section(SettingsL10n.string("Extensions")) {
        ProfileExtensionsSection(
          model: extensionManager(profile.id),
          onAddExtensions: { onAddExtensions(profile.id) })
      }
      Section {
        Button(SettingsL10n.string("Delete Profile…"), role: .destructive) {
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

  private func profileSymbolBinding(_ profile: BrowserSettingsProfile) -> Binding<String> {
    Binding(
      get: { profiles.first(where: { $0.id == profile.id })?.symbol ?? profile.symbol },
      set: { _ = onSetProfileSymbol(profile.id, $0) })
  }

  private func saveProfileName(_ profile: BrowserSettingsProfile) {
    guard let name = profileNameEdits[profile.id],
      name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else { return }
    if onRenameProfile(profile.id, name) { profileNameEdits[profile.id] = nil }
  }

  private func spaceCountLabel(_ count: Int) -> String {
    BrowserLocalization.plural("%d Spaces", count: count, table: "Settings")
  }

}

struct ConnectedAccountRow: View {
  let account: ConnectedAccount
  var disconnect: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      AccountAvatar(account: account)
      VStack(alignment: .leading, spacing: 1) {
        if let name = account.name {
          Text(name).lineLimit(1)
        } else {
          Text(account.email).lineLimit(1)
            .environment(\.layoutDirection, .leftToRight)
        }
        if account.name == nil {
          Text(account.provider.title)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text(account.email)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .environment(\.layoutDirection, .leftToRight)
        }
      }
      Spacer(minLength: 0)
      if let disconnect { Button(SettingsL10n.string("Disconnect"), action: disconnect) }
    }
  }
}

/// The account's photo, or the provider's mark while it loads, when it fails, or when the
/// provider has none.
private struct AccountAvatar: View {
  let account: ConnectedAccount

  var body: some View {
    AsyncImage(url: account.photoURL) { phase in
      if let image = phase.image {
        image.resizable().scaledToFill()
      } else if let logo = account.provider.logo {
        Image(nsImage: logo).resizable().padding(5)
      }
    }
    .frame(width: 28, height: 28)
    .clipShape(Circle())
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
            Text(SettingsL10n.string(statuses[permission]?.label ?? "Checking…"))
              .foregroundStyle(.secondary)
            if let url = permission.settingsURL {
              Button(SettingsL10n.string("Open Settings")) { NSWorkspace.shared.open(url) }
            }
          }
        } label: {
          Label(SettingsL10n.string(permission.title), systemImage: permission.symbol)
        }
      }
    } header: {
      Text(SettingsL10n.string("macOS Permissions"))
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
