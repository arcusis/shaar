// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func onboardingSignInProgressLabelIsLocalized() {
  #expect(
    ProfileOnboardingAccessibility.signInProgressLabel(provider: "Google", language: .english)
      == "Finish signing in to Google in the sign-in window.")
  #expect(
    ProfileOnboardingAccessibility.signInProgressLabel(provider: "Google", language: .hebrew)
      == "יש להשלים את ההתחברות אל \u{2068}Google\u{2069} בחלון ההתחברות.")
}

@MainActor
private final class OnboardingRecorder {
  var signIns: [(profile: BrowserProfile, provider: AccountProvider)] = []
  var pendingSignIn: ((ConnectedAccount?) -> Void)?
  var stoppedSignIns = 0
  var drafts: [ProfileDraft] = []
  var outcomes: [ProfileOnboardingModel.Outcome] = []
  var creationError: Error?
  let createdID = UUID()

  func model(spaceID: UUID? = nil) -> ProfileOnboardingModel {
    ProfileOnboardingModel(
      spaceID: spaceID,
      actions: ProfileOnboardingActions(
        connect: { [unowned self] profile, option, completion in
          signIns.append((profile, option.provider))
          pendingSignIn = completion
        },
        stopConnecting: { [unowned self] in
          stoppedSignIns += 1
          pendingSignIn?(nil)
        },
        create: { [unowned self] draft in
          drafts.append(draft)
          if let creationError { throw creationError }
          return createdID
        },
        close: { [unowned self] in outcomes.append($0) }))
  }

  func finishSignIn(_ account: ConnectedAccount?) {
    let completion = pendingSignIn
    pendingSignIn = nil
    completion?(account)
  }
}

private struct CreationFailure: Error {}

@Suite @MainActor struct ProfileOnboardingTests {
  @Test func onboardingStepTitleIsVoiceOverHeading() {
    #expect(OnboardingStepHeader.headingTraits == .isHeader)
  }

  @Test func stepsAdvanceSkipAndGoBackInOrder() {
    let model = OnboardingRecorder().model()
    #expect(model.step == .name)
    #expect(!model.canContinue && !model.canGoBack && !model.canSkip)
    model.name = "   "
    model.continueToNext()
    #expect(model.step == .name)
    model.name = "Work"
    for step in [ProfileOnboardingStep.icon, .color, .account] {
      model.continueToNext()
      #expect(model.step == step)
    }
    #expect(model.canSkip && model.canGoBack && !model.canContinue)
    model.skip()
    #expect(model.step == .done && !model.canSkip)
    for step in [ProfileOnboardingStep.account, .color, .icon, .name] {
      model.back()
      #expect(model.step == step)
    }
    model.back()
    #expect(model.step == .name)
  }

  @Test(arguments: AccountProvider.allCases)
  func eachProviderConnectsOnlyAtAccountStepWithTheDraftIdentity(_ provider: AccountProvider) {
    let recorder = OnboardingRecorder()
    let model = recorder.model()
    model.name = "  Work  "
    model.color = ProfileColorChoice(tint: .ocean)
    model.symbol = "💼"
    model.connect(provider)
    #expect(recorder.signIns.isEmpty)
    advanceToAccount(model)
    model.connect(provider)
    #expect(recorder.signIns.map(\.provider) == [provider])
    #expect(recorder.signIns.first?.profile.id == model.profileID)
    #expect(recorder.signIns.first?.profile.name == "Work")
    #expect(recorder.signIns.first?.profile.symbol == "💼")
    #expect(recorder.signIns.first?.profile.tint == .ocean)
    #expect(!model.canSkip && !model.canGoBack && !model.canContinue)
    let account = ConnectedAccount(provider: provider, email: "alex@example.test")
    recorder.finishSignIn(account)
    #expect(model.stepAccount == account && model.canContinue && !model.canSkip)
    for other in AccountProvider.allCases { model.connect(other) }
    #expect(recorder.signIns.count == 1)
    model.continueToNext()
    #expect(model.step == .done)
    model.back()
    #expect(model.step == .account && model.stepAccount == account)
    #expect(recorder.drafts.isEmpty)
  }

  @Test func abandonedOrWrongProviderCompletionDoesNotConnect() {
    let recorder = OnboardingRecorder()
    let model = recorder.model()
    model.name = "Work"
    advanceToAccount(model)
    model.connect(.apple)
    recorder.finishSignIn(nil)
    #expect(model.canSkip && model.stepAccount == nil)
    model.connect(.apple)
    recorder.finishSignIn(ConnectedAccount(provider: .google, email: "wrong@example.test"))
    #expect(model.canSkip && model.stepAccount == nil)
  }

  @Test func retryIgnoresAnEarlierAttemptsLateCallback() {
    let recorder = OnboardingRecorder()
    let model = recorder.model()
    model.name = "Work"
    advanceToAccount(model)
    model.connect(.apple)
    let stale = recorder.pendingSignIn
    recorder.finishSignIn(nil)
    model.connect(.apple)
    stale?(ConnectedAccount(provider: .apple, email: "stale@example.test"))
    #expect(model.connecting == .apple && model.stepAccount == nil)
    recorder.finishSignIn(ConnectedAccount(provider: .apple, email: "current@example.test"))
    #expect(model.stepAccount?.email == "current@example.test")
  }

  @Test func cancelCreatesNothingAndIgnoresLateCompletion() {
    let recorder = OnboardingRecorder()
    let model = recorder.model(spaceID: UUID())
    model.name = "Work"
    advanceToAccount(model)
    model.connect(.google)
    let late = recorder.pendingSignIn
    model.cancel()
    late?(ConnectedAccount(provider: .google, email: "late@example.test"))
    model.skip()
    model.continueToNext()
    model.cancel()
    #expect(recorder.stoppedSignIns == 1)
    #expect(model.connectedAccounts.isEmpty && recorder.drafts.isEmpty)
    #expect(recorder.outcomes == [.cancelled])
  }

  @Test func doneCreatesExactlyOnceWithAllChoicesAndOneAccount() {
    let recorder = OnboardingRecorder()
    let spaceID = UUID()
    let model = recorder.model(spaceID: spaceID)
    model.name = " Client "
    model.symbol = "paintpalette"
    model.color = ProfileColorChoice(customRGB: SpaceRGBColor(red: 12, green: 34, blue: 56))
    advanceToAccount(model)
    model.connect(.microsoft)
    let account = ConnectedAccount(provider: .microsoft, email: "worker@example.test")
    recorder.finishSignIn(account)
    model.continueToNext()
    #expect(recorder.drafts.isEmpty && model.step == .done)
    model.continueToNext()
    model.continueToNext()
    model.cancel()
    #expect(recorder.drafts.count == 1)
    let draft = recorder.drafts[0]
    #expect(draft.id == model.profileID && draft.name == "Client")
    #expect(draft.symbol == "paintpalette" && draft.profile.symbol == "paintpalette")
    #expect(draft.color == model.color && draft.accounts == [account] && draft.spaceID == spaceID)
    #expect(recorder.outcomes == [.created(recorder.createdID)])
  }

  @Test func failedCreationAllowsRetryWithoutRepeatingSignIn() {
    let recorder = OnboardingRecorder()
    recorder.creationError = CreationFailure()
    let model = recorder.model()
    model.name = "Work"
    advanceToAccount(model)
    model.skip()
    model.continueToNext()
    #expect(
      model.failure == SettingsL10n.string("Could not create the profile. Try again.")
        && model.outcome == nil && recorder.outcomes.isEmpty)
    recorder.creationError = nil
    model.continueToNext()
    #expect(recorder.drafts.count == 2 && recorder.signIns.isEmpty)
    #expect(recorder.outcomes == [.created(recorder.createdID)])
  }

  @Test func profileCreationFailureHasNaturalHebrewCopy() {
    #expect(
      ProfileOnboardingModel.creationFailure(language: .hebrew)
        == "לא ניתן ליצור את הפרופיל. כדאי לנסות שוב.")
  }

  private func advanceToAccount(_ model: ProfileOnboardingModel) {
    for _ in 0..<3 { model.continueToNext() }
  }

  @Test func draftCreatesTheProfileWithItsIdentityColorAccountsAndSpace() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let session = BrowserSession.fresh()
    let workspace = try BrowserWorkspaceStore(file: file, initialSession: session)
    let preferences = BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json"))
    let spaceID = session.selectedSpaceID
    let account = ConnectedAccount(provider: .google, email: "alex@acme.test")
    let draft = ProfileDraft(
      id: UUID(), name: "Work", color: ProfileColorChoice(tint: .rose), accounts: [account],
      spaceID: spaceID)

    let id = try draft.create(in: workspace, preferences: preferences)

    #expect(id == draft.id)
    let profile = try #require(workspace.workspace.catalog.profiles.first { $0.id == id })
    #expect(profile.name == "Work" && profile.tint == .rose)
    #expect(workspace.workspace.catalog.spaces.first { $0.id == spaceID }?.profileID == id)
    #expect(preferences.accounts(for: id) == [account])
    try workspace.flushSaves()
    #expect(try file.load() == workspace.workspace)
    #expect(throws: WorkspaceError.self) {
      try draft.create(in: workspace, preferences: preferences)
    }
    #expect(workspace.workspace.catalog.profiles.filter { $0.id == id }.count == 1)
  }

  @Test func draftForASpaceRemovedMeanwhileStillCreatesTheProfile() throws {
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let before = workspace.workspace.catalog.spaces.map(\.profileID)
    let draft = ProfileDraft(
      id: UUID(), name: "Work", color: .none, accounts: [], spaceID: UUID())

    let id = try draft.create(in: workspace, preferences: BrowserPreferencesStore())

    #expect(workspace.workspace.catalog.profiles.contains { $0.id == id })
    #expect(workspace.workspace.catalog.spaces.map(\.profileID) == before)
  }

  @Test func settingsShowAndEditTheProfileColor() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    let profileID = try #require(settings.profiles.first?.id)
    let custom = ProfileColorChoice(customRGB: SpaceRGBColor(red: 1, green: 2, blue: 3))

    #expect(settings.profiles.first?.color == ProfileColorChoice.none)
    #expect(settings.setProfileColor(profileID, to: custom))
    #expect(settings.profiles.first?.color == custom)
    #expect(settings.profiles.first?.color.rgb == SpaceRGBColor(red: 1, green: 2, blue: 3))
    #expect(!settings.setProfileColor(UUID(), to: custom))
    try workspace.flushSaves()
    #expect(try file.load()?.catalog.profiles.first?.customRGB == custom.customRGB)
  }

  @Test func settingsShowAndEditTheProfileSymbol() throws {
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    let profileID = try #require(settings.profiles.first?.id)

    #expect(settings.profiles.first?.symbol == BrowserProfile.defaultSymbol)
    #expect(settings.setProfileSymbol(profileID, to: "star.fill"))
    #expect(settings.profiles.first?.symbol == "star.fill")
    #expect(!settings.setProfileSymbol(profileID, to: ""))
    #expect(!settings.setProfileSymbol(UUID(), to: "star"))
    #expect(workspace.workspace.catalog.profiles.first?.symbol == "star.fill")
  }

  @Test func presetColorResolvesToItsTintAndCustomColorWins() {
    #expect(ProfileColorChoice.none.rgb == nil)
    #expect(ProfileColorChoice(tint: .ocean).rgb == SpaceTintRGB.color(for: .ocean))
    let custom = SpaceRGBColor(red: 9, green: 8, blue: 7)
    #expect(ProfileColorChoice(tint: .ocean, customRGB: custom).rgb == custom)
  }
}
