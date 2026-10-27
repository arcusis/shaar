import BrowserCore
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import ArcusisBrowser

private func saveFixtureCredential() -> NativePasswordSubmittedCredential {
  NativePasswordSubmittedCredential(username: "synthetic-user", password: "synthetic-password")
}

@MainActor
private final class SaveBridgeDouble: NativePasswordSubmissionBridge {
  var callback: ((Result<NativePasswordSubmittedCredential, NativePasswordSaveFailure>) -> Void)?
  var consumeCount = 0
  var cancelCount = 0
  var onCancel: (() -> Void)?
  var onBind: (() -> Void)?
  var allowBind = true
  var authority: NativePasswordSaveDispatchAuthority?

  func bindAuthority(
    submission: NativePasswordSubmission, authority: NativePasswordSaveDispatchAuthority
  ) -> Bool {
    self.authority = authority
    onBind?()
    return allowBind
  }

  func consume(
    submission: NativePasswordSubmission,
    completion: @escaping (
      Result<NativePasswordSubmittedCredential, NativePasswordSaveFailure>
    ) -> Void
  ) {
    consumeCount += 1
    callback = completion
  }
  func cancel(offerID: UUID) {
    cancelCount += 1
    onCancel?()
  }
}

@MainActor
private final class SaveVaultDouble: NativePasswordSaveVault {
  var prepareReply: ((Result<NativePasswordSaveAdmission, NativePasswordSaveFailure>) -> Void)?
  var writeReply: ((NativePasswordSaveRawWriteResult) -> Void)?
  var reconcileReply: ((NativePasswordSaveReconciliationResult) -> Void)?
  var reconcileCount = 0
  var authority: NativePasswordSaveDispatchAuthority?
  var decision: NativePasswordSaveDecision?
  var writeCount = 0
  var cancelCount = 0
  var receivedSyntheticCredential = false

  func prepare(
    submission: NativePasswordSubmission,
    completion: @escaping (Result<NativePasswordSaveAdmission, NativePasswordSaveFailure>) -> Void
  ) { prepareReply = completion }

  func write(
    submission: NativePasswordSubmission, admission: NativePasswordSaveAdmission,
    decision: NativePasswordSaveDecision, credential: NativePasswordSubmittedCredential,
    authority: NativePasswordSaveDispatchAuthority,
    completion: @escaping (NativePasswordSaveRawWriteResult) -> Void
  ) {
    writeCount += 1
    self.decision = decision
    self.authority = authority
    receivedSyntheticCredential = credential.username == "synthetic-user"
      && credential.password == "synthetic-password"
    writeReply = completion
  }

  func reconcile(
    submission: NativePasswordSubmission, admission: NativePasswordSaveAdmission,
    decision: NativePasswordSaveDecision,
    completion: @escaping (NativePasswordSaveReconciliationResult) -> Void
  ) {
    reconcileCount += 1
    reconcileReply = completion
  }

  func cancel(offerID: UUID) { cancelCount += 1 }
}

@Suite @MainActor
struct NativePasswordSaveCoordinatorTests {
  private func offer(deadline: TimeInterval = 20) throws -> NativePasswordSubmission {
    let profile = UUID()
    let owner = NativePasswordSubmissionOwner(
      browser: PasswordFillBinding(windowID: UUID(), profileID: profile, tabID: UUID()),
      account: PasswordAuthenticationBinding(
        profileID: profile, vaultID: UUID(), accountID: UUID(),
        authority: try #require(URL(string: "https://vault.example"))),
      ownerEpoch: UUID())
    let origin = try #require(PasswordFillOrigin("https://login.example"))
    let url = try #require(
      PasswordFillDocumentURL("https://login.example/signin?synthetic=1", origin: origin))
    return NativePasswordSubmission(
      id: UUID(), owner: owner, origin: origin, documentURL: url,
      provenance: .htmlForm, deadline: deadline)
  }

  private func admission(_ submission: NativePasswordSubmission) -> NativePasswordSaveAdmission {
    NativePasswordSaveAdmission(
      owner: submission.owner, sessionID: UUID(), snapshotTicket: UUID(),
      accountLabel: "Synthetic vault", allowCreate: true,
      choices: [
        NativePasswordSaveChoice(id: UUID(), name: "Existing login", username: "synthetic-user")
      ])
  }

  private func confirmation(
    _ submission: NativePasswordSubmission, _ admission: NativePasswordSaveAdmission,
    decision: NativePasswordSaveDecision, cipherID: UUID
  ) -> NativePasswordSaveConfirmation {
    NativePasswordSaveConfirmation(
      offerID: submission.id, owner: submission.owner, sessionID: admission.sessionID,
      freshSnapshotTicket: UUID(), decision: decision, cipherID: cipherID)
  }

  @Test func saveRequiresExplicitConsentAndOneShotDispatch() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    let accepted = admission(submission)
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(accepted))
    #expect(coordinator.presentation?.originalSite == "https://login.example")
    #expect(bridge.consumeCount == 0)
    coordinator.save()
    #expect(bridge.consumeCount == 1)
    #expect(coordinator.presentation == nil)
    let callback = try #require(bridge.callback)
    callback(.success(saveFixtureCredential()))
    callback(.success(saveFixtureCredential()))
    #expect(vault.writeCount == 1)
    #expect(vault.receivedSyntheticCredential)
    #expect(vault.decision == .create)
    let authority = try #require(vault.authority)
    #expect(authority.claim(binding: authority.binding, now: 10))
    #expect(!authority.claim(binding: authority.binding, now: 10))
    coordinator.cancel()
    vault.writeReply?(.rejectedBeforeDispatch)
    #expect(outcomes == [.unconfirmed])
  }

  @Test func updateRequiresExplicitListedChoice() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    let accepted = admission(submission)
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { _ in }
    vault.prepareReply?(.success(accepted))
    coordinator.update(UUID())
    #expect(bridge.consumeCount == 0)
    coordinator.update(accepted.choices[0].id)
    bridge.callback?(.success(saveFixtureCredential()))
    #expect(vault.decision == .update(accepted.choices[0].id))
    coordinator.cancel()
  }

  @Test func ownerChangeRejectsDelayedResultsAndCompletesOnce() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    let accepted = admission(submission)
    var owner: NativePasswordSubmissionOwner? = submission.owner
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    let reply = try #require(vault.prepareReply)
    owner = nil
    coordinator.invalidateOwner()
    reply(.success(accepted))
    #expect(coordinator.presentation == nil)
    #expect(outcomes == [.failed(.stale)])
    #expect(bridge.consumeCount == 0 && vault.writeCount == 0)
  }

  @Test func admissionFromAnotherAccountAndDuplicateChoicesAreRejected() throws {
    let submission = try offer()
    for duplicate in [false, true] {
      let bridge = SaveBridgeDouble()
      let vault = SaveVaultDouble()
      let accepted = admission(submission)
      let other = try offer()
      let bad = NativePasswordSaveAdmission(
        owner: duplicate ? submission.owner : other.owner,
        sessionID: accepted.sessionID, snapshotTicket: accepted.snapshotTicket,
        accountLabel: accepted.accountLabel, allowCreate: true,
        choices: duplicate ? [accepted.choices[0], accepted.choices[0]] : accepted.choices)
      var outcomes: [NativePasswordSaveOutcome] = []
      let coordinator = NativePasswordSaveCoordinator(
        bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
      coordinator.present(submission) { outcomes.append($0) }
      vault.prepareReply?(.success(bad))
      #expect(outcomes == [.failed(.stale)])
      #expect(coordinator.presentation == nil)
      #expect(bridge.consumeCount == 0 && vault.writeCount == 0)
    }
  }

  @Test func emptyAdmissionDoesNotPresentOrConsume() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    let accepted = admission(submission)
    let empty = NativePasswordSaveAdmission(
      owner: submission.owner, sessionID: accepted.sessionID,
      snapshotTicket: accepted.snapshotTicket, accountLabel: accepted.accountLabel,
      allowCreate: false, choices: [])
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(empty))
    #expect(outcomes == [.failed(.stale)])
    #expect(coordinator.presentation == nil)
    #expect(bridge.consumeCount == 0 && vault.writeCount == 0)
  }

  @Test func missingConsumeReplyExpiresAndLateReplyCannotWrite() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    var time: TimeInterval = 10
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { time })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(admission(submission)))
    coordinator.save()
    let late = try #require(bridge.callback)
    time = 20
    coordinator.expireIfNeeded()
    late(.success(saveFixtureCredential()))
    #expect(outcomes == [.failed(.expired)])
    #expect(vault.writeCount == 0)
  }

  @Test func cancelledOfferCannotBePresentedAgain() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    coordinator.cancel()
    coordinator.present(submission) { outcomes.append($0) }
    #expect(outcomes == [.failed(.cancelled), .failed(.stale)])
    #expect(coordinator.presentation == nil && vault.writeCount == 0)
  }

  @Test func browserRevocationBlocksLateCredentialAndDispatchClaim() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(admission(submission)))
    coordinator.save()
    let authority = try #require(bridge.authority)
    #expect(!authority.revoke())
    bridge.callback?(.success(saveFixtureCredential()))
    #expect(vault.writeCount == 0)
    #expect(!authority.claim(binding: authority.binding, now: 10))
    #expect(outcomes == [.failed(.stale)])
  }

  @Test func rawWriteCannotConfirmBeforeFreshReconciliation() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    let accepted = admission(submission)
    let selected = accepted.choices[0].id
    let decision = NativePasswordSaveDecision.update(selected)
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(accepted))
    coordinator.update(selected)
    bridge.callback?(.success(saveFixtureCredential()))
    let authority = try #require(vault.authority)
    #expect(authority.claim(binding: authority.binding, now: 10))
    let rawReply = try #require(vault.writeReply)
    rawReply(.possiblyDispatched)
    rawReply(.possiblyDispatched)
    #expect(outcomes.isEmpty && vault.reconcileCount == 1)
    let proof = confirmation(submission, accepted, decision: decision, cipherID: selected)
    let reconcileReply = try #require(vault.reconcileReply)
    reconcileReply(.confirmed(proof))
    reconcileReply(.confirmed(proof))
    #expect(outcomes == [.confirmed(proof)])
  }

  @Test func cancellationAfterClaimBeatsLateReconciliation() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    let accepted = admission(submission)
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(accepted))
    coordinator.save()
    bridge.callback?(.success(saveFixtureCredential()))
    let authority = try #require(vault.authority)
    #expect(authority.claim(binding: authority.binding, now: 10))
    vault.writeReply?(.possiblyDispatched)
    let late = try #require(vault.reconcileReply)
    coordinator.cancel()
    late(.confirmed(confirmation(submission, accepted, decision: .create, cipherID: UUID())))
    #expect(outcomes == [.unconfirmed])
  }

  @Test func staleOrWrongReconciliationNeverConfirms() throws {
    let submission = try offer()
    for wrongCipher in [false, true] {
      let bridge = SaveBridgeDouble()
      let vault = SaveVaultDouble()
      let accepted = admission(submission)
      let selected = accepted.choices[0].id
      let decision = NativePasswordSaveDecision.update(selected)
      var outcomes: [NativePasswordSaveOutcome] = []
      let coordinator = NativePasswordSaveCoordinator(
        bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
      coordinator.present(submission) { outcomes.append($0) }
      vault.prepareReply?(.success(accepted))
      coordinator.update(selected)
      bridge.callback?(.success(saveFixtureCredential()))
      let authority = try #require(vault.authority)
      #expect(authority.claim(binding: authority.binding, now: 10))
      vault.writeReply?(.possiblyDispatched)
      let proof = NativePasswordSaveConfirmation(
        offerID: submission.id, owner: submission.owner, sessionID: accepted.sessionID,
        freshSnapshotTicket: wrongCipher ? UUID() : accepted.snapshotTicket,
        decision: decision, cipherID: wrongCipher ? UUID() : selected)
      vault.reconcileReply?(.confirmed(proof))
      #expect(outcomes == [.unconfirmed])
    }
  }

  @Test func bindReentrancyInvalidatesBeforeConsume() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(admission(submission)))
    bridge.onBind = { [weak coordinator] in coordinator?.invalidateOwner() }
    coordinator.save()
    #expect(outcomes == [.failed(.stale)])
    #expect(bridge.consumeCount == 0 && vault.writeCount == 0)
    let authority = try #require(bridge.authority)
    #expect(!authority.claim(binding: authority.binding, now: 10))
  }

  @Test func invalidDeadlinesDoNotPrepareOrConsume() throws {
    for deadline in [10.0, 41.0, Double.infinity, Double.nan] {
      let submission = try offer(deadline: deadline)
      let bridge = SaveBridgeDouble()
      let vault = SaveVaultDouble()
      var outcomes: [NativePasswordSaveOutcome] = []
      let coordinator = NativePasswordSaveCoordinator(
        bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { 10 })
      coordinator.present(submission) { outcomes.append($0) }
      #expect(outcomes == [.failed(.stale)])
      #expect(vault.prepareReply == nil && bridge.consumeCount == 0)
    }
  }

  @Test func invalidatingOneOwnerDoesNotCancelAnotherProfile() throws {
    let first = try offer()
    let second = try offer()
    let firstBridge = SaveBridgeDouble()
    let secondBridge = SaveBridgeDouble()
    let firstVault = SaveVaultDouble()
    let secondVault = SaveVaultDouble()
    var firstOutcomes: [NativePasswordSaveOutcome] = []
    var secondOutcomes: [NativePasswordSaveOutcome] = []
    let firstCoordinator = NativePasswordSaveCoordinator(
      bridge: firstBridge, vault: firstVault, currentOwner: { first.owner }, now: { 10 })
    let secondCoordinator = NativePasswordSaveCoordinator(
      bridge: secondBridge, vault: secondVault, currentOwner: { second.owner }, now: { 10 })
    firstCoordinator.present(first) { firstOutcomes.append($0) }
    secondCoordinator.present(second) { secondOutcomes.append($0) }
    firstVault.prepareReply?(.success(admission(first)))
    secondVault.prepareReply?(.success(admission(second)))
    firstCoordinator.invalidateOwner()
    #expect(firstOutcomes == [.failed(.stale)])
    #expect(secondCoordinator.presentation != nil)
    #expect(secondOutcomes.isEmpty)
    secondCoordinator.cancel()
    #expect(secondOutcomes == [.failed(.cancelled)])
  }

  @Test func timeoutAndReentrantBridgeCancellationCannotReleaseSecrets() throws {
    let submission = try offer()
    let bridge = SaveBridgeDouble()
    let vault = SaveVaultDouble()
    var time: TimeInterval = 10
    var outcomes: [NativePasswordSaveOutcome] = []
    let coordinator = NativePasswordSaveCoordinator(
      bridge: bridge, vault: vault, currentOwner: { submission.owner }, now: { time })
    coordinator.present(submission) { outcomes.append($0) }
    vault.prepareReply?(.success(admission(submission)))
    coordinator.save()
    bridge.onCancel = { [weak bridge] in
      bridge?.callback?(.success(saveFixtureCredential()))
    }
    time = 20
    coordinator.expireIfNeeded()
    #expect(outcomes == [.failed(.expired)])
    #expect(vault.writeCount == 0)
    #expect(bridge.cancelCount == 1 && vault.cancelCount == 1)
  }

  @Test func revokeWinsBeforeClaimAndClaimMakesCancellationUnconfirmed() throws {
    let submission = try offer()
    let admission = admission(submission)
    let binding = NativePasswordSaveGrantBinding(
      offerID: submission.id, owner: submission.owner, sessionID: admission.sessionID,
      snapshotTicket: admission.snapshotTicket, decision: .create, deadline: submission.deadline)
    let revoked = NativePasswordSaveDispatchAuthority(binding: binding)
    #expect(!revoked.revoke())
    #expect(!revoked.claim(binding: binding, now: 10))
    let claimed = NativePasswordSaveDispatchAuthority(binding: binding)
    #expect(claimed.claim(binding: binding, now: 10))
    #expect(claimed.revoke())
    let expired = NativePasswordSaveDispatchAuthority(binding: binding)
    #expect(!expired.claim(binding: binding, now: 20))
    var wrong = binding
    wrong = NativePasswordSaveGrantBinding(
      offerID: UUID(), owner: wrong.owner, sessionID: wrong.sessionID,
      snapshotTicket: wrong.snapshotTicket, decision: wrong.decision, deadline: wrong.deadline)
    #expect(!expired.claim(binding: wrong, now: 10))
  }

  @Test func concurrentClaimHasExactlyOneWinner() throws {
    let submission = try offer()
    let accepted = admission(submission)
    let binding = NativePasswordSaveGrantBinding(
      offerID: submission.id, owner: submission.owner, sessionID: accepted.sessionID,
      snapshotTicket: accepted.snapshotTicket, decision: .create, deadline: submission.deadline)
    let authority = NativePasswordSaveDispatchAuthority(binding: binding)
    let results = Mutex<[Bool]>([])
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      let claimed = authority.claim(binding: binding, now: 10)
      results.withLock { $0.append(claimed) }
    }
    #expect(results.withLock { $0.filter { $0 }.count } == 1)
  }

  @Test func metadataAndDiagnosticsDoNotExposeSubmissionURLOrSecrets() throws {
    let submission = try offer()
    let credential = saveFixtureCredential()
    #expect(!String(reflecting: submission).contains("synthetic=1"))
    #expect(!String(reflecting: credential).contains("synthetic-password"))
    #expect(!String(reflecting: credential).contains("synthetic-user"))
  }
}
