// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI

enum BrowserSettingsAccessibility {
  static func profileSelectionTraits(isSelected: Bool) -> AccessibilityTraits {
    isSelected ? .isSelected : []
  }

  static func openSpaceLabel(
    name: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Open %@", table: "Settings", language: language, arguments: [.string(name)])
  }

  static func disconnectAccountLabel(
    account: ConnectedAccount, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Disconnect %@ from %@", table: "Settings", language: language,
      arguments: [.string(account.email), .string(account.provider.title)])
  }

  static func openPermissionSettingsLabel(
    name: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Open %@ Settings", table: "Settings", language: language, arguments: [.string(name)])
  }

  static func resetPermissionsLabel(
    origin: String, language: BrowserLanguage = .currentLaunchLanguage
  ) -> String {
    BrowserLocalization.format(
      "Reset permissions for %@", table: "Settings", language: language,
      arguments: [.string(origin)])
  }
}

struct BrowserSettingsProfile: Identifiable {
  let id: UUID
  let name: String
  let color: ProfileColorChoice
  let symbol: String
  let spaces: [BrowserSettingsSpace]
  let accounts: [ConnectedAccount]
  let downloadDirectory: URL?
  let defaultDownloadDirectory: URL?
  let canChooseDownloadDirectory: Bool
  var spaceCount: Int { spaces.count }
  var spaceNames: [String] { spaces.map(\.name) }

  init(
    id: UUID, name: String, color: ProfileColorChoice = .none,
    symbol: String = BrowserProfile.defaultSymbol, spaces: [BrowserSettingsSpace],
    accounts: [ConnectedAccount] = [], downloadDirectory: URL? = nil,
    defaultDownloadDirectory: URL? = nil, canChooseDownloadDirectory: Bool = false
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.symbol = symbol
    self.spaces = spaces
    self.accounts = accounts
    self.downloadDirectory = downloadDirectory
    self.defaultDownloadDirectory = defaultDownloadDirectory
    self.canChooseDownloadDirectory = canChooseDownloadDirectory
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
  static let profilesHeadingTraits: AccessibilityTraits = .isHeader

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
        if let selection = BrowserLanguage(rawValue: rawValue), rawValue != selectedLanguage {
          BrowserLanguage.selection = selection
          selectedLanguage = selection.rawValue
          restartError = nil
          confirmLanguageRestart = selection != BrowserLanguage.launchSelection
        }
      })
  }
  @State private var confirmLanguageRestart = false
  @State private var restartError: String?
  @State private var defaultStatus = false
  @State private var defaultError: String?
  @State private var historyMessage: String?
  @State private var clearingHistory = false
  @State private var confirmHistory = false
  @Binding var sidebarInitiallyVisible: Bool
  @Binding var selectedSearchEngine: String
  let storageNotice: String?
  let downloadDirectoryErrors: [UUID: String]
  let onRestart: (() -> String?)?
  let onAddProfile: () -> Void
  let onRenameProfile: (UUID, String) -> Bool
  let onSetProfileColor: (UUID, ProfileColorChoice) -> Bool
  let onSetProfileSymbol: (UUID, String) -> Bool
  let onChooseDownloadDirectory: (UUID) -> Void
  let onResetDownloadDirectory: (UUID) -> Void
  let onDeleteProfile: (UUID, UUID?) async throws -> Void
  let onOpenSpace: (UUID) -> Void
  let onConnectAccount: (UUID, AccountSignInOption) -> Void
  let onDisconnectAccount: (UUID, AccountProvider) -> Void
  let extensionManager: (UUID) -> ExtensionManagerModel?
  let sharedExtensions: SharedExtensionSettingsModel?
  let onAddExtensions: (UUID) -> Void
  let onLoadUnpacked: (UUID) -> Void
  let pageOrigin: (UUID) -> String?
  let selectedTabID: (UUID) -> UUID?
  let clearHistory: ((UUID) async throws -> Void)?
  let profileBackend: (any ProfileSettingsBackend)?
  let httpsOnlyModeEnabled: (UUID) -> Bool
  let onSetHttpsOnlyMode: (UUID, Bool) -> Bool
  @State private var httpsOnlyMode = true
  @State private var httpsOnlyAppliesNextOpen = false
  @State private var deletingProfile: BrowserSettingsProfile?
  @State private var selectedSection: BrowserSettingsSection
  @State private var profileNameEdits: [UUID: String] = [:]
  @State private var profileSymbolPickerIsPresented = false

  init(
    profiles: [BrowserSettingsProfile], searchEngines: [BrowserSettingsChoice],
    selectedProfileID: Binding<UUID?>, sidebarInitiallyVisible: Binding<Bool>,
    selectedSearchEngine: Binding<String>, storageNotice: String? = nil,
    downloadDirectoryErrors: [UUID: String] = [:],
    onRestart: (() -> String?)? = nil,
    onAddProfile: @escaping () -> Void = {},
    onRenameProfile: @escaping (UUID, String) -> Bool = { _, _ in false },
    onSetProfileColor: @escaping (UUID, ProfileColorChoice) -> Bool = { _, _ in false },
    onSetProfileSymbol: @escaping (UUID, String) -> Bool = { _, _ in false },
    onChooseDownloadDirectory: @escaping (UUID) -> Void = { _ in },
    onResetDownloadDirectory: @escaping (UUID) -> Void = { _ in },
    onDeleteProfile: @escaping (UUID, UUID?) async throws -> Void = { _, _ in
      throw CocoaError(.featureUnsupported)
    },
    onOpenSpace: @escaping (UUID) -> Void = { _ in },
    onConnectAccount: @escaping (UUID, AccountSignInOption) -> Void = { _, _ in },
    onDisconnectAccount: @escaping (UUID, AccountProvider) -> Void = { _, _ in },
    extensionManager: @escaping (UUID) -> ExtensionManagerModel? = { _ in nil },
    sharedExtensions: SharedExtensionSettingsModel? = nil,
    onAddExtensions: @escaping (UUID) -> Void = { _ in },
    onLoadUnpacked: @escaping (UUID) -> Void = { _ in },
    pageOrigin: @escaping (UUID) -> String? = { _ in nil },
    selectedTabID: @escaping (UUID) -> UUID? = { _ in nil },
    profileBackend: (any ProfileSettingsBackend)? = nil,
    clearHistory: ((UUID) async throws -> Void)? = nil,
    httpsOnlyModeEnabled: @escaping (UUID) -> Bool,
    onSetHttpsOnlyMode: @escaping (UUID, Bool) -> Bool,
    initialSection: BrowserSettingsSection = .general,
    confirmsClearHistoryOnAppear: Bool = false
  ) {
    self.profiles = profiles
    self.searchEngines = searchEngines
    _selectedProfileID = selectedProfileID
    _sidebarInitiallyVisible = sidebarInitiallyVisible
    _selectedSearchEngine = selectedSearchEngine
    self.storageNotice = storageNotice
    self.downloadDirectoryErrors = downloadDirectoryErrors
    self.onRestart = onRestart
    self.onAddProfile = onAddProfile
    self.onRenameProfile = onRenameProfile
    self.onSetProfileColor = onSetProfileColor
    self.onSetProfileSymbol = onSetProfileSymbol
    self.onChooseDownloadDirectory = onChooseDownloadDirectory
    self.onResetDownloadDirectory = onResetDownloadDirectory
    self.onDeleteProfile = onDeleteProfile
    self.onOpenSpace = onOpenSpace
    self.onConnectAccount = onConnectAccount
    self.onDisconnectAccount = onDisconnectAccount
    self.extensionManager = extensionManager
    self.sharedExtensions = sharedExtensions
    self.onAddExtensions = onAddExtensions
    self.onLoadUnpacked = onLoadUnpacked
    self.pageOrigin = pageOrigin
    self.selectedTabID = selectedTabID
    self.clearHistory = clearHistory
    self.profileBackend = profileBackend
    self.httpsOnlyModeEnabled = httpsOnlyModeEnabled
    self.onSetHttpsOnlyMode = onSetHttpsOnlyMode
    _selectedSection = State(initialValue: initialSection)
    _confirmHistory = State(initialValue: confirmsClearHistoryOnAppear)
  }

  static func historyClearFailure(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.string(
      "Could not clear history. Try again.", table: "Settings", language: language)
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
    .alert(SettingsL10n.string("Restart Shaar to apply"), isPresented: $confirmLanguageRestart) {
      Button(SettingsL10n.string("Later"), role: .cancel) {}
      if let onRestart {
        Button(SettingsL10n.string("Restart Shaar")) { restartError = onRestart() }
      }
    } message: {
      Text(SettingsL10n.string("Your windows and tabs will be restored."))
    }
    .sheet(item: $deletingProfile) { profile in
      ProfileDeletionConfirmation(
        profile: profile, profiles: profiles, onDeleteProfile: onDeleteProfile,
        onDismiss: { deletingProfile = nil })
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
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
        .accessibilityLabel(section.title)
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

  @AppStorage(DevelopmentModePreference.key) private var developmentModeEnabled = true
  @AppStorage(SleepingTabPreferences.enabledKey) private var sleepInactiveTabs = true
  @AppStorage(SleepingTabPreferences.timeoutMinutesKey) private var sleepTimeoutMinutes =
    SleepingTabPreferences.defaultTimeoutMinutes
  @AppStorage(SleepingTabPreferences.neverSleepHostsKey) private var neverSleepHosts = ""

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
      Section(SettingsL10n.string("Sleeping tabs")) {
        Toggle(SettingsL10n.string("Sleep inactive tabs"), isOn: $sleepInactiveTabs)
          .accessibilityIdentifier("settings-sleep-inactive-tabs")
        Picker(
          SettingsL10n.string("Inactive tabs are discarded after"), selection: $sleepTimeoutMinutes
        ) {
          Text(SettingsL10n.string("5 minutes")).tag(5)
          Text(SettingsL10n.string("15 minutes")).tag(15)
          Text(SettingsL10n.string("30 minutes")).tag(30)
          Text(SettingsL10n.string("1 hour")).tag(60)
          Text(SettingsL10n.string("2 hours")).tag(120)
          Text(SettingsL10n.string("6 hours")).tag(360)
        }
        .disabled(!sleepInactiveTabs)
        .accessibilityIdentifier("settings-sleep-timeout")
        TextField(
          SettingsL10n.string("Sites that never sleep"), text: $neverSleepHosts, axis: .vertical
        )
        .lineLimit(2...4)
        .accessibilityLabel(SettingsL10n.string("Sites that never sleep"))
        .accessibilityIdentifier("settings-never-sleep-hosts")
        Text(
          SettingsL10n.string(
            "One site per line. Pinned and visible tabs, tabs playing sound or using camera, microphone, or screen capture, and tabs with unsaved form input stay awake."
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section(SettingsL10n.string("Developer")) {
        Toggle(
          SettingsL10n.string("Automatically turn on Dev Mode for local development pages"),
          isOn: $developmentModeEnabled)
      }
      Section(SettingsL10n.string("Windows")) {
        Picker(
          SettingsL10n.string("Links from other apps open in"),
          selection: $externalLinksInMainWindow
        ) {
          Text(SettingsL10n.string("Mini window")).tag(false)
          Text(SettingsL10n.string("Main window")).tag(true)
        }
        Toggle(SettingsL10n.string("Warn before quitting with Command-Q"), isOn: $warnBeforeQuit)
      }
      Section {
        Picker(SettingsL10n.string("Language"), selection: languageSelection) {
          Text(SettingsL10n.string("System Default")).tag(BrowserLanguage.systemDefault.rawValue)
          Text(verbatim: "English").tag(BrowserLanguage.english.rawValue)
          Text("עברית").tag(BrowserLanguage.hebrew.rawValue)
        }
        Text(SettingsL10n.string("Language changes after you restart the app."))
          .font(.caption).foregroundStyle(.secondary)
        if selectedLanguage != BrowserLanguage.launchSelection.rawValue, let onRestart {
          BrowserLanguageRestartPrompt(onRestart: { restartError = onRestart() })
        }
        if let restartError { Text(restartError).foregroundStyle(.red) }
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
    defaultStatus = DefaultBrowserService.isDefault()
  }

  private func setDefaultBrowser() {
    Task {
      do {
        try await DefaultBrowserService.makeDefault()
        defaultError = nil
      } catch { defaultError = SettingsL10n.string("Could not set the default browser.") }
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
      if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
        Section {
          Toggle(
            SettingsL10n.string("Always use secure connections"), isOn: $httpsOnlyMode
          )
          .accessibilityIdentifier("settings.httpsOnlyMode")
          .onChange(of: httpsOnlyMode) { _, enabled in
            guard httpsOnlyModeEnabled(selectedProfileID) != enabled else { return }
            let appliedNow = onSetHttpsOnlyMode(selectedProfileID, enabled)
            httpsOnlyAppliesNextOpen = !appliedNow
          }
        } footer: {
          Text(httpsOnlyFooter)
        }
        if let profileBackend {
          ProfilePrivacySections(profileID: selectedProfileID, backend: profileBackend)
            .id(selectedProfileID)
        }
      }
      Section {
        LabeledContent(
          SettingsL10n.string("Cookies and site storage"),
          value: SettingsL10n.string("Engine controlled"))
        LabeledContent(
          SettingsL10n.string("Trackers"),
          value: SettingsL10n.string("Engine controlled"))
        LabeledContent(
          SettingsL10n.string("HTTPS-only browsing"),
          value: SettingsL10n.string("Engine controlled"))
        LabeledContent(
          SettingsL10n.string("Referrers"),
          value: SettingsL10n.string("Engine controlled"))
        LabeledContent(
          SettingsL10n.string("WebRTC local IP exposure"),
          value: SettingsL10n.string("Engine controlled"))
        LabeledContent(
          SettingsL10n.string("Extensions"),
          value: SettingsL10n.string("Engine controlled"))
      } header: {
        Text(SettingsL10n.string("Private Windows"))
      } footer: {
        Text(
          SettingsL10n.string(
            "The private start page shows which protections are active. Use site controls to allow cookies for a specific site."
          ))
      }
      MacPermissionsSection()
    }.formStyle(.grouped)
      .onAppear { refreshHttpsOnlyMode() }
      .onChange(of: selectedProfileID) { _, _ in refreshHttpsOnlyMode() }
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
              historyMessage = Self.historyClearFailure()
            }
            clearingHistory = false
          }
        }
      }
  }

  private var httpsOnlyFooter: String {
    if httpsOnlyAppliesNextOpen {
      return SettingsL10n.string(
        "Public pages use HTTPS. A site that does not support HTTPS shows a warning instead of loading. This profile applies the change the next time it opens."
      )
    }
    return SettingsL10n.string(
      "Public pages use HTTPS. A site that does not support HTTPS shows a warning instead of loading."
    )
  }

  private func refreshHttpsOnlyMode() {
    httpsOnlyAppliesNextOpen = false
    guard let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID })
    else { return }
    let enabled = httpsOnlyModeEnabled(selectedProfileID)
    if httpsOnlyMode != enabled { httpsOnlyMode = enabled }
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
          Text(SettingsL10n.string("Profiles"))
            .font(.headline)
            .accessibilityAddTraits(Self.profilesHeadingTraits)
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
              ProfileIdentityBadge(
                account: profile.accounts.first, color: profile.color.rgb, symbol: profile.symbol)
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).lineLimit(1)
                if let account = profile.accounts.first {
                  Text(account.displayName).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
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
            .accessibilityAddTraits(
              BrowserSettingsAccessibility.profileSelectionTraits(
                isSelected: selectedProfileID == profile.id))
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
            .accessibilityLabel(SettingsL10n.string("Profile name"))
            .accessibilityIdentifier("settings.renameProfile")
            .onSubmit { saveProfileName(profile) }
          Button(SettingsL10n.string("Save")) { saveProfileName(profile) }
            .disabled(!ProfileNameEditPolicy.canSave(profileNameEdits[profile.id]))
        }
        ProfileColorPicker(color: profileColorBinding(profile))
          .accessibilityIdentifier("settings.profileColor")
        Picker(SettingsL10n.string("Search engine"), selection: $selectedSearchEngine) {
          ForEach(searchEngines) { Text($0.title).tag($0.id) }
        }
      }
      if profile.canChooseDownloadDirectory {
        Section(SettingsL10n.string("Download folder")) {
          LabeledContent(SettingsL10n.string("Current folder")) {
            Text(
              (profile.downloadDirectory ?? profile.defaultDownloadDirectory)?.path
                ?? SettingsL10n.string("Unavailable")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
          }
          HStack {
            Button(SettingsL10n.string("Choose Folder…")) {
              onChooseDownloadDirectory(profile.id)
            }
            .accessibilityIdentifier("settings.downloadFolder.choose")
            if profile.downloadDirectory != nil {
              Button(SettingsL10n.string("Use Default")) {
                onResetDownloadDirectory(profile.id)
              }
              .accessibilityIdentifier("settings.downloadFolder.reset")
            }
          }
          if let error = downloadDirectoryErrors[profile.id] {
            Text(error)
              .foregroundStyle(.red)
              .accessibilityIdentifier("settings.downloadFolder.error")
          }
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
                .accessibilityLabel(BrowserSettingsAccessibility.openSpaceLabel(name: space.name))
            }
          }
        }
      }
      Section {
        ForEach(profile.accounts, id: \.provider) { account in
          ConnectedAccountRow(account: account, color: profile.color.rgb) {
            onDisconnectAccount(profile.id, account.provider)
          }
        }
        ForEach(
          AccountSignInOption.allCases.filter {
            AccountProvider.connectable(alongside: profile.accounts).contains($0.provider)
          }
        ) { option in
          Button {
            onConnectAccount(profile.id, option)
          } label: {
            HStack(spacing: 10) {
              if let logo = option.provider.logo {
                Image(nsImage: logo).resizable().frame(width: 18, height: 18)
              }
              Text(SettingsL10n.format("Connect %@", .string(option.title)))
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("settings.connect.\(option.rawValue)")
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
          sharedModel: sharedExtensions,
          pageOrigin: { pageOrigin(profile.id) },
          selectedTabID: { selectedTabID(profile.id) },
          onAddExtensions: { onAddExtensions(profile.id) },
          onLoadUnpacked: { onLoadUnpacked(profile.id) })
      }
      Section {
        Button(SettingsL10n.string("Delete Profile…"), role: .destructive) {
          deletingProfile = profile
        }
        .disabled(profiles.count < 2 || profileBackend == nil)
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
      ProfileNameEditPolicy.canSave(name)
    else { return }
    if onRenameProfile(profile.id, name) { profileNameEdits[profile.id] = nil }
  }

  private func spaceCountLabel(_ count: Int) -> String {
    BrowserLocalization.plural("%d Spaces", count: count, table: "Settings")
  }

}

enum ProfileNameEditPolicy {
  static func canSave(_ edit: String?) -> Bool {
    edit?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }
}

struct BrowserLanguageRestartPrompt: View {
  static let headingTraits: AccessibilityTraits = .isHeader

  let onRestart: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(SettingsL10n.string("Restart Shaar to apply"))
        .font(.headline)
        .accessibilityAddTraits(Self.headingTraits)
      Text(SettingsL10n.string("Your windows and tabs will be restored."))
        .font(.caption).foregroundStyle(.secondary)
      Button(SettingsL10n.string("Restart Shaar"), action: onRestart)
    }
  }
}

struct ConnectedAccountRow: View {
  let account: ConnectedAccount
  var color: SpaceRGBColor?
  var disconnect: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      ProfileIdentityBadge(account: account, color: color)
      VStack(alignment: .leading, spacing: 1) {
        if account.displayName != account.email {
          Text(account.displayName).lineLimit(1)
        } else {
          Text(account.email).lineLimit(1)
            .environment(\.layoutDirection, .leftToRight)
        }
        if account.displayName == account.email {
          Text(account.provider.title)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text(account.email)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .environment(\.layoutDirection, .leftToRight)
        }
      }
      Spacer(minLength: 0)
      if let disconnect {
        Button(SettingsL10n.string("Disconnect"), action: disconnect)
          .accessibilityLabel(
            BrowserSettingsAccessibility.disconnectAccountLabel(account: account))
      }
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
            Text(SettingsL10n.string(statuses[permission]?.label ?? "Checking…"))
              .foregroundStyle(.secondary)
            if let url = permission.settingsURL {
              Button(SettingsL10n.string("Open Settings")) { NSWorkspace.shared.open(url) }
                .accessibilityLabel(
                  BrowserSettingsAccessibility.openPermissionSettingsLabel(
                    name: permission.title))
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
        SettingsL10n.string(
          "Websites can only use what macOS allows. If a site's request is blocked here, change it in System Settings."
        ))
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
