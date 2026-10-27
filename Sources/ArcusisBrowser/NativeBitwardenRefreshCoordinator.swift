import BrowserCore
import Foundation

struct NativeBitwardenRefreshResponse: Sendable {
  let accessToken: String
  let refreshToken: String?
  let expiresIn: UInt64
}

enum NativeBitwardenRefreshFailure: Error, Equatable {
  case reauthenticationRequired
  case stale
  case invalidResponse
}

/// Main-actor ownership makes generation invalidation synchronous with controller changes.
/// The credential lease remains held through intent, rotation, persistence and publication.
@MainActor
final class NativeBitwardenRefreshCoordinator {
  typealias Transport =
    @MainActor (PasswordSessionRecoveryRecord) async throws
    -> NativeBitwardenRefreshResponse

  private let binding: PasswordAuthenticationBinding
  private let store: PasswordCredentialStore
  private let lease: PasswordCredentialSessionLock
  private let transport: Transport
  private let now: @MainActor () -> Date
  private let isOwner: @MainActor () -> Bool
  private let publish: @MainActor (String) -> Void
  private let revoke: @MainActor () -> Void
  private var record: PasswordSessionRecoveryRecord
  private var generation = 0
  private var invalidated = false
  private var inFlight: Task<PasswordCredential, Error>?
  private let expirySkew: TimeInterval = 60

  init(
    binding: PasswordAuthenticationBinding, record: PasswordSessionRecoveryRecord,
    store: PasswordCredentialStore, lease: PasswordCredentialSessionLock,
    now: @escaping @MainActor () -> Date = { Date() },
    transport: @escaping Transport, isOwner: @escaping @MainActor () -> Bool,
    publish: @escaping @MainActor (String) -> Void, revoke: @escaping @MainActor () -> Void
  ) throws {
    guard record.belongs(to: binding), record.state == .ready, try !lease.hasPendingRotation()
    else {
      throw NativeBitwardenRefreshFailure.reauthenticationRequired
    }
    self.binding = binding
    self.record = record
    self.store = store
    self.lease = lease
    self.now = now
    self.transport = transport
    self.isOwner = isOwner
    self.publish = publish
    self.revoke = revoke
  }

  var revision: UInt64 { record.revision }

  @discardableResult
  func invalidate() -> Task<PasswordCredential, Error>? {
    generation += 1
    invalidated = true
    let task = inFlight
    inFlight = nil
    task?.cancel()
    revoke()
    return task
  }

  /// A 401 caller supplies the revision used by its failed request. If another
  /// request already rotated that revision, reuse its result rather than rotate again.
  func ensureFresh(force: Bool = false, observedRevision: UInt64? = nil) async throws
    -> PasswordCredential
  {
    guard !invalidated, isOwner() else { throw NativeBitwardenRefreshFailure.stale }
    if force, let observedRevision, observedRevision > record.revision {
      throw NativeBitwardenRefreshFailure.stale
    }
    if let inFlight {
      let credential = try await inFlight.value
      guard !invalidated, isOwner() else { throw NativeBitwardenRefreshFailure.stale }
      return credential
    }
    if force, let observedRevision, observedRevision != record.revision {
      guard observedRevision < record.revision else { throw NativeBitwardenRefreshFailure.stale }
      if let expiry = record.credential.expiresAt,
        expiry.timeIntervalSince(now()) > expirySkew
      {
        return record.credential
      }
    }
    guard let expiry = record.credential.expiresAt else {
      invalidate()
      throw NativeBitwardenRefreshFailure.reauthenticationRequired
    }
    if !force && expiry.timeIntervalSince(now()) > expirySkew { return record.credential }
    let ticket = generation
    let task = Task { @MainActor in try await self.rotate(ticket: ticket) }
    inFlight = task
    do {
      let result = try await task.value
      if generation == ticket { inFlight = nil }
      guard !invalidated, isOwner() else { throw NativeBitwardenRefreshFailure.stale }
      return result
    } catch {
      if generation == ticket { inFlight = nil }
      throw error
    }
  }

  func performReadOnlySync<Value>(
    _ operation: @MainActor () async throws -> Value
  ) async throws -> Value {
    _ = try await ensureFresh()
    let observed = revision
    do {
      return try await operation()
    } catch NativeBitwardenBackendError.unauthorized {
      _ = try await ensureFresh(force: true, observedRevision: observed)
      return try await operation()
    }
  }

  private func rotate(ticket: Int) async throws -> PasswordCredential {
    guard !invalidated, isOwner() else { throw NativeBitwardenRefreshFailure.stale }
    guard let oldRefresh = record.credential.refreshToken, !oldRefresh.isEmpty,
      record.revision < UInt64.max
    else {
      do {
        try lease.markPendingRotation(revision: record.revision)
      } catch {
        invalidate()
        throw error
      }
      invalidate()
      throw NativeBitwardenRefreshFailure.reauthenticationRequired
    }
    let ready = record
    let intent = try ready.replacing(
      credential: ready.credential, revision: ready.revision, state: .refreshInFlight)
    do {
      try lease.markPendingRotation(revision: ready.revision)
      try store.writeRecovery(intent, for: binding, expected: .record(ready), lease: lease)
    } catch {
      invalidate()
      throw error
    }
    do {
      try Task.checkCancellation()
      let result = try await transport(ready)
      guard generation == ticket, !invalidated, isOwner(), !Task.isCancelled else {
        throw NativeBitwardenRefreshFailure.stale
      }
      let credential = try Self.validated(result, oldRefresh: oldRefresh, record: ready, now: now())
      let replacement = try ready.replacing(
        credential: credential, revision: ready.revision + 1, state: .ready)
      try store.writeRecovery(replacement, for: binding, expected: .record(intent), lease: lease)
      let verified = try store.readRecovery(
        for: binding, identityURL: ready.identityURL, apiURL: ready.apiURL,
        serviceID: ready.serviceID, deviceID: ready.deviceID, clientID: ready.clientID,
        sdkRevision: ready.sdkRevision,
        lease: lease)
      guard verified == .record(replacement) else {
        throw PasswordCredentialStoreError.recoveryConflict
      }
      guard generation == ticket, !invalidated, isOwner() else {
        throw NativeBitwardenRefreshFailure.stale
      }
      try lease.clearPendingRotation()
      record = replacement
      publish(credential.accessToken)
      return credential
    } catch {
      if generation == ticket, !invalidated {
        // Preserve the original marker after any ambiguous write or request.
        invalidate()
      }
      throw error
    }
  }

  static func validateInitial(_ record: PasswordSessionRecoveryRecord, now: Date) throws
    -> PasswordCredential
  {
    guard let expiry = record.credential.expiresAt else {
      throw NativeBitwardenRefreshFailure.invalidResponse
    }
    let seconds = expiry.timeIntervalSince(now)
    guard seconds.isFinite, seconds > 0, seconds <= 604_800 else {
      throw NativeBitwardenRefreshFailure.invalidResponse
    }
    return try validated(
      NativeBitwardenRefreshResponse(
        accessToken: record.credential.accessToken, refreshToken: record.credential.refreshToken,
        expiresIn: UInt64(seconds)),
      oldRefresh: record.credential.refreshToken ?? "", record: record, now: now)
  }

  static func validateStored(_ record: PasswordSessionRecoveryRecord) throws {
    let token = record.credential.accessToken
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard token.utf8.count <= 8192, parts.count == 3,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
      let expiry = record.credential.expiresAt, expiry.timeIntervalSince1970.isFinite
    else { throw NativeBitwardenRefreshFailure.invalidResponse }
    let body = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padded = body + String(repeating: "=", count: (4 - body.count % 4) % 4)
    guard let data = Data(base64Encoded: padded), data.count <= 6144,
      let claims = try? JSONDecoder().decode(Claims.self, from: data),
      UUID(uuidString: claims.sub) == record.accountID, claims.clientID == record.clientID,
      claims.exp.isFinite, claims.exp > 0,
      expiry.timeIntervalSince1970 <= claims.exp,
      claims.exp - expiry.timeIntervalSince1970 < 301
    else { throw NativeBitwardenRefreshFailure.invalidResponse }
  }

  private struct Claims: Decodable {
    let sub: String
    let clientID: String
    let exp: TimeInterval
    enum CodingKeys: String, CodingKey {
      case sub
      case clientID = "client_id"
      case exp
    }
  }

  private static func validated(
    _ result: NativeBitwardenRefreshResponse, oldRefresh: String,
    record: PasswordSessionRecoveryRecord, now: Date
  ) throws -> PasswordCredential {
    let parts = result.accessToken.split(separator: ".", omittingEmptySubsequences: false)
    guard result.accessToken.utf8.count <= 8192, parts.count == 3,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
      result.expiresIn > 0, result.expiresIn <= 604_800,
      result.refreshToken.map({ !$0.isEmpty && $0.utf8.count <= 8192 }) ?? true
    else { throw NativeBitwardenRefreshFailure.invalidResponse }
    let body = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padded = body + String(repeating: "=", count: (4 - body.count % 4) % 4)
    guard let data = Data(base64Encoded: padded), data.count <= 6144,
      let claims = try? JSONDecoder().decode(Claims.self, from: data),
      UUID(uuidString: claims.sub) == recordAccount(record), claims.clientID == record.clientID,
      claims.exp.isFinite, now.timeIntervalSince1970.isFinite,
      claims.exp > now.timeIntervalSince1970,
      abs(claims.exp - (now.timeIntervalSince1970 + Double(result.expiresIn))) <= 300
    else { throw NativeBitwardenRefreshFailure.invalidResponse }
    // Encoding Date uses a different epoch; rounding down avoids a fractional
    // conversion increasing the persisted expiry beyond the authenticated claim.
    let expiry = Date(
      timeIntervalSince1970: floor(
        min(claims.exp, now.timeIntervalSince1970 + Double(result.expiresIn))))
    guard expiry > now else { throw NativeBitwardenRefreshFailure.invalidResponse }
    return PasswordCredential(
      accessToken: result.accessToken, refreshToken: result.refreshToken ?? oldRefresh,
      expiresAt: expiry)
  }

  private static func recordAccount(_ record: PasswordSessionRecoveryRecord) -> UUID {
    record.accountID
  }
}
