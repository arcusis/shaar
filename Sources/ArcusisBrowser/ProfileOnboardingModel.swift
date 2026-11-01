// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation

enum ProfileOnboardingStep: Int, CaseIterable {
  case details, google, microsoft, done

  var provider: AccountProvider? {
    switch self {
    case .google: .google
    case .microsoft: .microsoft
    case .details, .done: nil
    }
  }

  var title: String {
    switch self {
    case .details: SettingsL10n.string("Name, icon and color")
    case .google: SettingsL10n.string("Connect Google")
    case .microsoft: SettingsL10n.string("Connect Microsoft")
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
    let liveSpaceID = spaceID.flatMap { id in
      workspace.workspace.catalog.spaces.contains { $0.id == id } ? id : nil
    }
    let id = try workspace.createProfile(profile, assigningSpace: liveSpaceID)
    for account in accounts { preferences.setAccount(account, for: id) }
    return id
  }
}

/// Work the onboarding window hands to its host: account sign-in, creation and closing.
struct ProfileOnboardingActions {
  /// Signs the not yet created profile in; reports the account, or nil when abandoned.
  var connect: (BrowserProfile, AccountProvider, @escaping (ConnectedAccount?) -> Void) -> Void
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
  private(set) var step = ProfileOnboardingStep.details
  private(set) var accounts: [AccountProvider: ConnectedAccount] = [:]
  private(set) var connecting: AccountProvider?
  private(set) var outcome: Outcome?
  private(set) var failure: String?
  @ObservationIgnored private let actions: ProfileOnboardingActions

  init(spaceID: UUID? = nil, actions: ProfileOnboardingActions) {
    self.spaceID = spaceID
    self.actions = actions
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var isBusy: Bool { connecting != nil || outcome != nil }
  var canGoBack: Bool { step.previous != nil && !isBusy }
  var canSkip: Bool { step.provider != nil && stepAccount == nil && !isBusy }

  var canContinue: Bool {
    switch step {
    case .details: !trimmedName.isEmpty && !isBusy
    case .google, .microsoft: stepAccount != nil && !isBusy
    case .done: !isBusy
    }
  }

  /// The account connected on the current step, if it is an account step.
  var stepAccount: ConnectedAccount? { step.provider.flatMap { accounts[$0] } }

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
    guard canGoBack, let previous = reachableStep(from: step, moving: \.previous) else { return }
    failure = nil
    step = previous
  }

  func connect(_ provider: AccountProvider) {
    guard !isBusy, step.provider == provider, !trimmedName.isEmpty else { return }
    connecting = provider
    actions.connect(BrowserProfile(id: profileID, name: trimmedName), provider) {
      [weak self] account in self?.connectionFinished(provider, account: account)
    }
  }

  func cancel() {
    guard outcome == nil else { return }
    if connecting != nil { actions.stopConnecting() }
    connecting = nil
    outcome = .cancelled
    actions.close(.cancelled)
  }

  private func advance() {
    guard let next = reachableStep(from: step, moving: \.next) else { return }
    failure = nil
    step = next
  }

  /// A profile has one account, so once a provider is connected the other provider's step is
  /// passed over in both directions.
  private func reachableStep(
    from start: ProfileOnboardingStep,
    moving move: (ProfileOnboardingStep) -> ProfileOnboardingStep?
  ) -> ProfileOnboardingStep? {
    var candidate = move(start)
    while let current = candidate, isPassedOver(current) { candidate = move(current) }
    return candidate
  }

  private func isPassedOver(_ step: ProfileOnboardingStep) -> Bool {
    guard let provider = step.provider, let connected = accounts.keys.first else { return false }
    return provider != connected
  }

  private func connectionFinished(_ provider: AccountProvider, account: ConnectedAccount?) {
    guard outcome == nil, connecting == provider else { return }
    connecting = nil
    if let account { accounts[provider] = account }
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
      failure = SettingsL10n.format(
        "The profile could not be created. %@", .string(error.localizedDescription))
    }
  }
}
