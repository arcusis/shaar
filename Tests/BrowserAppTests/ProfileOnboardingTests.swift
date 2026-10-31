// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

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
        connect: { [unowned self] profile, provider, completion in
          signIns.append((profile, provider))
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
  @Test func stepsAdvanceSkipAndGoBackInOrder() {
    let model = OnboardingRecorder().model()
    #expect(model.step == .details)
    #expect(!model.canContinue && !model.canGoBack && !model.canSkip)

    model.name = "   "
    model.continueToNext()
    #expect(model.step == .details)

    model.name = "Work"
    model.continueToNext()
    #expect(model.step == .google)
    #expect(model.canSkip && model.canGoBack && !model.canContinue)

    model.skip()
    #expect(model.step == .microsoft)
    model.skip()
    #expect(model.step == .done)
    #expect(!model.canSkip)

    model.back()
    model.back()
    #expect(model.step == .google)
    model.back()
    #expect(model.step == .details)
    model.back()
    #expect(model.step == .details)
  }

  @Test func accountsConnectToTheNotYetCreatedProfileIdentity() {
    let recorder = OnboardingRecorder()
    let model = recorder.model()
    model.name = "  Work  "
    model.continueToNext()

    model.connect(.microsoft)
    #expect(recorder.signIns.isEmpty)
    model.connect(.google)
    #expect(recorder.signIns.map(\.provider) == [.google])
    #expect(recorder.signIns.first?.profile.id == model.profileID)
    #expect(recorder.signIns.first?.profile.name == "Work")
    #expect(model.connecting == .google)
    #expect(!model.canSkip && !model.canGoBack && !model.canContinue)

    let workspaceAccount = ConnectedAccount(provider: .google, email: "alex@acme.test")
    recorder.finishSignIn(workspaceAccount)
    #expect(model.connecting == nil)
    #expect(model.stepAccount == workspaceAccount)
    #expect(model.canContinue && !model.canSkip)

    model.continueToNext()
    model.connect(.microsoft)
    recorder.finishSignIn(nil)
    #expect(model.stepAccount == nil)
    #expect(model.canSkip)
    #expect(recorder.drafts.isEmpty)
  }

  @Test func cancelCreatesNothingAndStopsARunningSignIn() {
    let recorder = OnboardingRecorder()
    let model = recorder.model(spaceID: UUID())
    model.name = "Work"
    model.continueToNext()
    model.connect(.google)

    model.cancel()
    #expect(recorder.stoppedSignIns == 1)
    #expect(recorder.outcomes == [.cancelled])
    #expect(model.outcome == .cancelled)

    recorder.finishSignIn(ConnectedAccount(provider: .google, email: "late@example.test"))
    model.skip()
    model.continueToNext()
    model.cancel()
    #expect(model.connectedAccounts.isEmpty)
    #expect(recorder.drafts.isEmpty)
    #expect(recorder.outcomes == [.cancelled])
  }

  @Test func doneCreatesTheProfileExactlyOnceWithEverythingGathered() {
    let recorder = OnboardingRecorder()
    let spaceID = UUID()
    let model = recorder.model(spaceID: spaceID)
    let color = ProfileColorChoice(customRGB: SpaceRGBColor(red: 12, green: 34, blue: 56))
    let microsoft = ConnectedAccount(provider: .microsoft, email: "worker@acme.test")
    model.name = " Client "
    model.color = color
    model.continueToNext()
    model.skip()
    model.connect(.microsoft)
    recorder.finishSignIn(microsoft)
    model.continueToNext()
    #expect(model.step == .done)
    #expect(recorder.drafts.isEmpty)

    model.continueToNext()
    model.continueToNext()
    model.cancel()

    #expect(recorder.drafts.count == 1)
    let draft = recorder.drafts[0]
    #expect(draft.id == model.profileID)
    #expect(draft.name == "Client")
    #expect(draft.color == color)
    #expect(draft.accounts == [microsoft])
    #expect(draft.spaceID == spaceID)
    #expect(recorder.outcomes == [.created(recorder.createdID)])
  }

  @Test func failedCreationKeepsTheOnboardingOpenForAnotherTry() {
    let recorder = OnboardingRecorder()
    recorder.creationError = CreationFailure()
    let model = recorder.model()
    model.name = "Work"
    model.continueToNext()
    model.skip()
    model.skip()

    model.continueToNext()
    #expect(model.failure != nil)
    #expect(model.outcome == nil && recorder.outcomes.isEmpty)

    recorder.creationError = nil
    model.continueToNext()
    #expect(recorder.drafts.count == 2)
    #expect(recorder.outcomes == [.created(recorder.createdID)])
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
    #expect(try file.load()?.catalog.profiles.first?.customRGB == custom.customRGB)
  }

  @Test func presetColorResolvesToItsTintAndCustomColorWins() {
    #expect(ProfileColorChoice.none.rgb == nil)
    #expect(ProfileColorChoice(tint: .ocean).rgb == SpaceTintRGB.color(for: .ocean))
    let custom = SpaceRGBColor(red: 9, green: 8, blue: 7)
    #expect(ProfileColorChoice(tint: .ocean, customRGB: custom).rgb == custom)
  }
}
