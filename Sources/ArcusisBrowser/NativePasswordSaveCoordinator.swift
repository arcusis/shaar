import Foundation
import Observation

/// Per-window source candidate. No engine or Controller adapter is installed here.
@MainActor @Observable
final class NativePasswordSaveCoordinator {
  struct Presentation: Equatable {
    let originalSite: String
    let accountLabel: String
    let allowCreate: Bool
    let choices: [NativePasswordSaveChoice]
  }

  private enum Phase { case preparing, offered, consuming, writing, reconciling }
  private final class Attempt {
    let submission: NativePasswordSubmission
    let completion: (NativePasswordSaveOutcome) -> Void
    var phase = Phase.preparing
    var admission: NativePasswordSaveAdmission?
    var authority: NativePasswordSaveDispatchAuthority?
    var expiry: Task<Void, Never>?

    init(
      submission: NativePasswordSubmission,
      completion: @escaping (NativePasswordSaveOutcome) -> Void
    ) {
      self.submission = submission
      self.completion = completion
    }
  }

  private(set) var presentation: Presentation?
  private(set) var busy = false
  @ObservationIgnored private let bridge: any NativePasswordSubmissionBridge
  @ObservationIgnored private let vault: any NativePasswordSaveVault
  @ObservationIgnored private let currentOwner: () -> NativePasswordSubmissionOwner?
  @ObservationIgnored private let now: () -> TimeInterval
  @ObservationIgnored private var attempt: Attempt?
  @ObservationIgnored private var seenOffers: [UUID: TimeInterval] = [:]

  init(
    bridge: any NativePasswordSubmissionBridge, vault: any NativePasswordSaveVault,
    currentOwner: @escaping () -> NativePasswordSubmissionOwner?,
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.bridge = bridge
    self.vault = vault
    self.currentOwner = currentOwner
    self.now = now
  }

  func present(
    _ submission: NativePasswordSubmission,
    completion: @escaping (NativePasswordSaveOutcome) -> Void
  ) {
    guard attempt == nil else {
      if attempt?.submission.id != submission.id { bridge.cancel(offerID: submission.id) }
      completion(.failed(.unavailable))
      return
    }
    let time = now()
    guard time.isFinite, submission.deadline.isFinite, submission.deadline > time,
      submission.deadline - time <= 30,
      submission.owner.browser.profileID == submission.owner.account.profileID,
      submission.documentURL.origin == submission.origin,
      currentOwner() == submission.owner, attempt == nil
    else {
      if attempt?.submission.id != submission.id { bridge.cancel(offerID: submission.id) }
      completion(.failed(.stale))
      return
    }
    seenOffers = seenOffers.filter { $0.value > time }
    guard seenOffers[submission.id] == nil, seenOffers.count < 128 else {
      bridge.cancel(offerID: submission.id)
      completion(.failed(.stale))
      return
    }
    seenOffers[submission.id] = submission.deadline

    let current = Attempt(submission: submission, completion: completion)
    attempt = current
    busy = true
    current.expiry = Task { @MainActor [weak self, weak current] in
      do { try await Task.sleep(for: .seconds(submission.deadline - time)) } catch { return }
      guard let self, let current, self.attempt === current else { return }
      self.expireIfNeeded()
    }
    vault.prepare(submission: submission) { [weak self, weak current] result in
      guard let self, let current, self.attempt === current, current.phase == .preparing else {
        return
      }
      guard self.valid(current) else {
        self.finish(current, .failed(.stale))
        return
      }
      switch result {
      case .failure(let error):
        self.finish(current, .failed(error))
      case .success(let admission):
        guard admission.owner == submission.owner, !admission.accountLabel.isEmpty,
          admission.allowCreate || !admission.choices.isEmpty,
          admission.accountLabel.utf8.count <= 1_024, admission.choices.count <= 5_000,
          Set(admission.choices.map(\.id)).count == admission.choices.count,
          admission.choices.allSatisfy({
            !$0.name.isEmpty && $0.name.utf8.count <= 1_024
              && ($0.username?.utf8.count ?? 0) <= 1_024
          })
        else {
          self.finish(current, .failed(.stale))
          return
        }
        current.admission = admission
        current.phase = .offered
        self.presentation = Presentation(
          originalSite: submission.origin.value, accountLabel: admission.accountLabel,
          allowCreate: admission.allowCreate, choices: admission.choices)
        self.busy = false
      }
    }
  }

  func save() { confirm(.create) }
  func update(_ id: UUID) { confirm(.update(id)) }

  private func confirm(_ decision: NativePasswordSaveDecision) {
    guard let current = attempt, current.phase == .offered, let admission = current.admission else {
      return
    }
    guard valid(current) else {
      finish(current, .failed(.stale))
      return
    }
    switch decision {
    case .create:
      guard admission.allowCreate else { return }
    case .update(let id):
      guard admission.choices.contains(where: { $0.id == id }) else { return }
    }
    let binding = NativePasswordSaveGrantBinding(
      offerID: current.submission.id, owner: current.submission.owner,
      sessionID: admission.sessionID, snapshotTicket: admission.snapshotTicket,
      decision: decision, deadline: current.submission.deadline)
    let authority = NativePasswordSaveDispatchAuthority(binding: binding)
    current.authority = authority
    current.phase = .consuming
    presentation = nil
    busy = true
    guard bridge.bindAuthority(submission: current.submission, authority: authority) else {
      finish(current, .failed(.stale))
      return
    }
    guard valid(current), authority.isAvailable(binding: binding, now: now()) else {
      finish(current, .failed(.stale))
      return
    }
    bridge.consume(submission: current.submission) { [weak self, weak current] result in
      guard let self, let current, self.attempt === current, current.phase == .consuming else {
        return
      }
      guard self.valid(current), authority.isAvailable(binding: binding, now: self.now()) else {
        self.finish(current, .failed(.stale))
        return
      }
      switch result {
      case .failure(let error):
        self.finish(current, .failed(error))
      case .success(let credential):
        guard !credential.password.isEmpty, credential.password.utf8.count <= 16_384,
          credential.username.utf8.count <= 1_024
        else {
          self.finish(current, .failed(.rejected))
          return
        }
        current.phase = .writing
        self.vault.write(
          submission: current.submission, admission: admission, decision: decision,
          credential: credential, authority: authority
        ) { [weak self, weak current] result in
          guard let self, let current, self.attempt === current, current.phase == .writing else {
            return
          }
          switch result {
          case .rejectedBeforeDispatch:
            self.finish(current, .failed(.rejected))
          case .possiblyDispatched:
            guard authority.wasClaimed, self.valid(current) else {
              self.finish(current, .unconfirmed)
              return
            }
            current.phase = .reconciling
            self.vault.reconcile(
              submission: current.submission, admission: admission, decision: decision
            ) { [weak self, weak current] result in
              guard let self, let current, self.attempt === current,
                current.phase == .reconciling
              else { return }
              guard self.valid(current), authority.wasClaimed else {
                self.finish(current, .unconfirmed)
                return
              }
              switch result {
              case .unresolved:
                self.finish(current, .unconfirmed)
              case .confirmed(let proof):
                guard proof.offerID == current.submission.id,
                  proof.owner == current.submission.owner,
                  proof.sessionID == admission.sessionID,
                  proof.freshSnapshotTicket != admission.snapshotTicket,
                  proof.decision == decision
                else {
                  self.finish(current, .unconfirmed)
                  return
                }
                if case .update(let id) = decision, proof.cipherID != id {
                  self.finish(current, .unconfirmed)
                  return
                }
                self.finish(current, .confirmed(proof), reconciled: true)
              }
            }
          }
        }
      }
    }
  }

  func cancel() {
    if let current = attempt { finish(current, .failed(.cancelled)) }
  }

  /// Owner must invoke synchronously on close, lock, disable or binding change.
  func invalidateOwner() {
    if let current = attempt { finish(current, .failed(.stale)) }
  }

  /// Also usable by the owner when its monotonic clock advances in a fixture.
  func expireIfNeeded() {
    guard let current = attempt else { return }
    let time = now()
    if !time.isFinite || time >= current.submission.deadline {
      finish(current, .failed(.expired))
    }
  }

  private func valid(_ current: Attempt) -> Bool {
    let time = now()
    return time.isFinite && time < current.submission.deadline
      && currentOwner() == current.submission.owner && attempt === current
  }

  private func finish(
    _ current: Attempt, _ outcome: NativePasswordSaveOutcome, reconciled: Bool = false
  ) {
    guard attempt === current else { return }
    attempt = nil
    presentation = nil
    busy = false
    current.expiry?.cancel()
    let dispatched = current.authority?.revoke() ?? false
    // Detach first: either cancellation call or completion may reenter.
    bridge.cancel(offerID: current.submission.id)
    vault.cancel(offerID: current.submission.id)
    if case .confirmed = outcome {
      current.completion(dispatched && reconciled ? outcome : .unconfirmed)
    } else {
      current.completion(dispatched ? .unconfirmed : outcome)
    }
  }
}
