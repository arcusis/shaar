// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

enum ProfileOnboardingStep: Int, CaseIterable {
  case name, icon, color, account, done

  var title: String {
    switch self {
    case .name: SettingsL10n.string("Name")
    case .icon: SettingsL10n.string("Icon")
    case .color: SettingsL10n.string("Color")
    case .account: SettingsL10n.string("Account")
    case .done: SettingsL10n.string("Ready")
    }
  }

  fileprivate var next: Self? { Self(rawValue: rawValue + 1) }
  fileprivate var previous: Self? { Self(rawValue: rawValue - 1) }
}

/// Everything onboarding gathered for the one profile it creates.
struct ProfileDraft: Equatable {
  let id: UUID
  let name: String
  let color: ProfileColorChoice
  var symbol = BrowserProfile.defaultSymbol
  let accounts: [ConnectedAccount]
  let spaceID: UUID?

  var profile: BrowserProfile {
    BrowserProfile(
      id: id, name: name, tint: color.tint, customRGB: color.customRGB, symbol: symbol)
  }

  /// Creates the profile with the identity its sign-ins already used, records those accounts,
  /// and gives it the requesting Space when that Space still exists.
  @MainActor
  func create(in workspace: BrowserWorkspaceStore, preferences: BrowserPreferencesStore) throws
    -> UUID
  {
    guard !workspace.workspace.catalog.profiles.contains(where: { $0.id == id }) else {
      throw WorkspaceError.invalidState
    }
    let liveSpaceID = spaceID.flatMap { id in
      workspace.workspace.catalog.spaces.contains { $0.id == id } ? id : nil
    }
    try workspace.validateWritableSnapshot()
    for account in accounts { try preferences.persistAccount(account, for: id) }
    do {
      return try workspace.createProfile(profile, assigningSpace: liveSpaceID)
    } catch {
      for account in accounts { preferences.removeAccount(account.provider, for: id) }
      throw error
    }
  }
}

/// Work the onboarding window hands to its host: account sign-in, creation and closing.
struct ProfileOnboardingActions {
  /// Signs the not yet created profile in; reports the account, or nil when abandoned.
  var connect: (BrowserProfile, AccountSignInOption, @escaping (ConnectedAccount?) -> Void) -> Void
  var stopConnecting: () -> Void
  var create: (ProfileDraft) throws -> UUID
  var close: (ProfileOnboardingModel.Outcome) -> Void
}

/// Drives New Profile onboarding. Nothing is written until Done, so Cancel leaves no profile.
@MainActor @Observable
final class ProfileOnboardingModel {
  enum Outcome: Equatable {
    case created(UUID)
    case cancelled
  }

  let profileID = UUID()
  let spaceID: UUID?
  var name = ""
  var color = ProfileColorChoice.none
  var symbol = BrowserProfile.defaultSymbol
  private(set) var step = ProfileOnboardingStep.name
  private(set) var accounts: [AccountProvider: ConnectedAccount] = [:]
  private(set) var connecting: AccountProvider?
  private(set) var outcome: Outcome?
  private(set) var failure: String?
  @ObservationIgnored private let actions: ProfileOnboardingActions
  @ObservationIgnored private var connectionID: UUID?

  init(spaceID: UUID? = nil, actions: ProfileOnboardingActions) {
    self.spaceID = spaceID
    self.actions = actions
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var isBusy: Bool { connecting != nil || outcome != nil }
  var canGoBack: Bool { step.previous != nil && !isBusy }
  var canSkip: Bool { step == .account && stepAccount == nil && !isBusy }

  var canContinue: Bool {
    switch step {
    case .name: !trimmedName.isEmpty && !isBusy
    case .icon, .color: !isBusy
    case .account: stepAccount != nil && !isBusy
    case .done: !isBusy
    }
  }

  var stepAccount: ConnectedAccount? { connectedAccounts.first }

  var connectedAccounts: [ConnectedAccount] {
    AccountProvider.allCases.compactMap { accounts[$0] }
  }

  func continueToNext() {
    guard canContinue else { return }
    if step == .done { return create() }
    advance()
  }

  func skip() {
    guard canSkip else { return }
    advance()
  }

  func back() {
    guard canGoBack, let previous = step.previous else { return }
    failure = nil
    step = previous
  }

  func connect(_ provider: AccountProvider) {
    connect(option: .standard(for: provider))
  }

  func connect(option: AccountSignInOption) {
    let provider = option.provider
    guard !isBusy, step == .account, accounts.isEmpty, !trimmedName.isEmpty else { return }
    connecting = provider
    let attempt = UUID()
    connectionID = attempt
    actions.connect(
      BrowserProfile(
        id: profileID, name: trimmedName, tint: color.tint, customRGB: color.customRGB,
        symbol: symbol), option
    ) {
      [weak self] account in self?.connectionFinished(provider, attempt: attempt, account: account)
    }
  }

  func cancel() {
    guard outcome == nil else { return }
    connectionID = nil
    if connecting != nil { actions.stopConnecting() }
    connecting = nil
    outcome = .cancelled
    actions.close(.cancelled)
  }

  private func advance() {
    guard let next = step.next else { return }
    failure = nil
    step = next
  }

  private func connectionFinished(
    _ provider: AccountProvider, attempt: UUID, account: ConnectedAccount?
  ) {
    guard outcome == nil, connecting == provider, connectionID == attempt else { return }
    connectionID = nil
    connecting = nil
    if let account, account.provider == provider { accounts = [provider: account] }
  }

  private func create() {
    let draft = ProfileDraft(
      id: profileID, name: trimmedName, color: color, symbol: symbol,
      accounts: connectedAccounts, spaceID: spaceID)
    do {
      let id = try actions.create(draft)
      outcome = .created(id)
      actions.close(.created(id))
    } catch {
      failure = SettingsL10n.string("Could not create this profile. Try again.")
    }
  }

  static func creationFailure(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.string("Could not create the profile. Try again.", table: "Settings", language: language)
  }
}
