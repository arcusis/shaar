import BrowserCore
import Foundation
import Synchronization

/// Engine-provided provenance; it does not prove remote authentication succeeded.
enum NativePasswordSubmissionProvenance: Equatable, Sendable {
  case htmlForm
  case xhr
  case sameDocument
}

struct NativePasswordSubmissionOwner: Equatable, Sendable {
  let browser: PasswordFillBinding
  let account: PasswordAuthenticationBinding
  let ownerEpoch: UUID
}

/// An adapter must obtain these values from the browser-owned offer, not the renderer.
struct NativePasswordSubmission: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let id: UUID
  let owner: NativePasswordSubmissionOwner
  let origin: PasswordFillOrigin
  let documentURL: PasswordFillDocumentURL
  let provenance: NativePasswordSubmissionProvenance
  /// Same monotonic clock domain as the coordinator, with the original deadline.
  let deadline: TimeInterval
  var description: String { "NativePasswordSubmission(<redacted>)" }
  var debugDescription: String { description }
}

struct NativePasswordSubmittedCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let username: String
  let password: String
  var description: String { "NativePasswordSubmittedCredential(<redacted>)" }
  var debugDescription: String { description }
}

struct NativePasswordSaveChoice: Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let username: String?
}

enum NativePasswordSaveDecision: Equatable, Sendable {
  case create
  case update(UUID)
}

/// Future Controller adapter binds this opaque ticket to the accepted SDK snapshot.
struct NativePasswordSaveAdmission: Equatable, Sendable {
  let owner: NativePasswordSubmissionOwner
  let sessionID: UUID
  let snapshotTicket: UUID
  let accountLabel: String
  let allowCreate: Bool
  let choices: [NativePasswordSaveChoice]
}

struct NativePasswordSaveGrantBinding: Equatable, Sendable {
  let offerID: UUID
  let owner: NativePasswordSubmissionOwner
  let sessionID: UUID
  let snapshotTicket: UUID
  let decision: NativePasswordSaveDecision
  let deadline: TimeInterval
}

/// Both browser and Controller adapters must revoke this same object synchronously.
/// The real backend must claim it at the same linearization point as its vault lease.
final class NativePasswordSaveDispatchAuthority: Sendable {
  private enum State: Sendable { case available, claimed, revoked }
  let binding: NativePasswordSaveGrantBinding
  private let state = Mutex(State.available)

  init(binding: NativePasswordSaveGrantBinding) { self.binding = binding }

  func isAvailable(binding: NativePasswordSaveGrantBinding, now: TimeInterval) -> Bool {
    state.withLock { state in
      guard case .available = state else { return false }
      return self.binding == binding && now.isFinite && now < binding.deadline
    }
  }

  var wasClaimed: Bool {
    state.withLock { state in
      if case .claimed = state { return true }
      return false
    }
  }

  func claim(binding: NativePasswordSaveGrantBinding, now: TimeInterval) -> Bool {
    state.withLock { state in
      guard case .available = state, self.binding == binding, now.isFinite,
        now < binding.deadline
      else { return false }
      state = .claimed
      return true
    }
  }

  /// Returns true if dispatch was already authorized and cannot be rolled back.
  @discardableResult
  func revoke() -> Bool {
    state.withLock { state in
      if case .claimed = state { return true }
      state = .revoked
      return false
    }
  }
}

enum NativePasswordSaveFailure: Error, Equatable, Sendable {
  case unavailable
  case stale
  case cancelled
  case expired
  case rejected
}

/// Construct only after the Controller accepts a fresh snapshot and verifies the intent.
struct NativePasswordSaveConfirmation: Equatable, Sendable {
  let offerID: UUID
  let owner: NativePasswordSubmissionOwner
  let sessionID: UUID
  let freshSnapshotTicket: UUID
  let decision: NativePasswordSaveDecision
  let cipherID: UUID
}

enum NativePasswordSaveOutcome: Equatable, Sendable {
  case failed(NativePasswordSaveFailure)
  /// A write may have reached the service; fresh sync is required.
  case unconfirmed
  case confirmed(NativePasswordSaveConfirmation)
}

/// Raw dispatch cannot claim success or supply a confirmation.
enum NativePasswordSaveRawWriteResult: Equatable, Sendable {
  case rejectedBeforeDispatch
  case possiblyDispatched
}

enum NativePasswordSaveReconciliationResult: Equatable, Sendable {
  case unresolved
  case confirmed(NativePasswordSaveConfirmation)
}

@MainActor
protocol NativePasswordSubmissionBridge: AnyObject {
  /// Install this exact authority before consume; browser invalidation revokes it synchronously.
  func bindAuthority(
    submission: NativePasswordSubmission, authority: NativePasswordSaveDispatchAuthority
  ) -> Bool
  /// Release secrets only after native consent; implementations must complete once.
  func consume(
    submission: NativePasswordSubmission,
    completion:
      @escaping (
        Result<NativePasswordSubmittedCredential, NativePasswordSaveFailure>
      ) -> Void
  )
  func cancel(offerID: UUID)
}

@MainActor
protocol NativePasswordSaveVault: AnyObject {
  /// Must validate Profile/account/session and return only eligible personal choices.
  func prepare(
    submission: NativePasswordSubmission,
    completion: @escaping (Result<NativePasswordSaveAdmission, NativePasswordSaveFailure>) -> Void
  )
  /// Must consume the same dispatch authority and Controller lease immediately before dispatch.
  func write(
    submission: NativePasswordSubmission, admission: NativePasswordSaveAdmission,
    decision: NativePasswordSaveDecision, credential: NativePasswordSubmittedCredential,
    authority: NativePasswordSaveDispatchAuthority,
    completion: @escaping (NativePasswordSaveRawWriteResult) -> Void
  )
  /// Must perform fresh Controller-accepted sync and verify the original write intent.
  /// If a create cannot be correlated uniquely, report unresolved.
  func reconcile(
    submission: NativePasswordSubmission, admission: NativePasswordSaveAdmission,
    decision: NativePasswordSaveDecision,
    completion: @escaping (NativePasswordSaveReconciliationResult) -> Void
  )
  func cancel(offerID: UUID)
}
