import BrowserCore
import Foundation

/// Capability is tied to one accepted encrypted snapshot and one SDK session.
struct NativeBitwardenFillAccess: Equatable, Sendable {
  let sessionID: UUID
  private let snapshotID: UUID

  fileprivate init(sessionID: UUID, snapshotID: UUID) {
    self.sessionID = sessionID
    self.snapshotID = snapshotID
  }
}

struct NativeBitwardenFillSnapshotAccess: Sendable {
  let access: NativeBitwardenFillAccess
  let snapshot: NativeBitwardenVaultSnapshot
}

struct NativeBitwardenFillCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let username: String
  let password: String
  var description: String { "NativeBitwardenFillCredential(<redacted>)" }
  var debugDescription: String { description }
}

enum NativeBitwardenFillError: Error, Equatable, Sendable {
  case staleAccess
  case syncInProgress
  case cipherUnavailable
  case organizationUnsupported
  case ineligibleCipher
  case repromptRequired
  case unsupportedMatch
  case noMatchingURI
}

struct NativeBitwardenSyncTicket: Sendable {
  fileprivate let revision: UUID
  fileprivate let operation: UUID
}

/// Optional capability; obtaining it does not install a product fill flow.
protocol NativeBitwardenFillCredentialBackend: Sendable {
  func fillSnapshot(sessionID: UUID) async throws -> NativeBitwardenFillSnapshotAccess
  func fillCredential(
    access: NativeBitwardenFillAccess, cipherID: UUID, context: PasswordFillContext
  ) async throws -> NativeBitwardenFillCredential
}

/// Used only inside the owning actor; callers recheck after every suspension.
struct NativeBitwardenFillAccessState<Item: Sendable>: Sendable {
  private struct Accepted: Sendable {
    let access: NativeBitwardenFillAccess
    let snapshot: NativeBitwardenVaultSnapshot
    let items: [UUID: Item]
    let organizationIDs: Set<UUID>
  }
  private let sessionID: UUID
  private var revision = UUID()
  private var syncOperation: UUID?
  private var accepted: Accepted?

  init(sessionID: UUID) { self.sessionID = sessionID }

  mutating func revoke() -> UUID {
    revision = UUID()
    accepted = nil
    return revision
  }

  mutating func beginSync() throws -> NativeBitwardenSyncTicket {
    let revision = revoke()
    guard syncOperation == nil else { throw NativeBitwardenFillError.syncInProgress }
    let operation = UUID()
    syncOperation = operation
    return NativeBitwardenSyncTicket(revision: revision, operation: operation)
  }

  mutating func finishSync(_ ticket: NativeBitwardenSyncTicket) {
    if syncOperation == ticket.operation { syncOperation = nil }
  }

  mutating func publish(
    ticket: NativeBitwardenSyncTicket, snapshot: NativeBitwardenVaultSnapshot, items: [UUID: Item],
    organizationIDs: Set<UUID> = []
  ) throws {
    guard revision == ticket.revision, syncOperation == ticket.operation, accepted == nil else {
      throw NativeBitwardenFillError.staleAccess
    }
    accepted = Accepted(
      access: NativeBitwardenFillAccess(sessionID: sessionID, snapshotID: ticket.revision),
      snapshot: snapshot, items: items, organizationIDs: organizationIDs)
  }

  func snapshot() throws -> NativeBitwardenFillSnapshotAccess {
    guard let accepted else { throw NativeBitwardenFillError.staleAccess }
    return NativeBitwardenFillSnapshotAccess(access: accepted.access, snapshot: accepted.snapshot)
  }

  func item(access: NativeBitwardenFillAccess, id: UUID) throws -> Item {
    guard let accepted, accepted.access == access else {
      throw NativeBitwardenFillError.staleAccess
    }
    guard let item = accepted.items[id] else { throw NativeBitwardenFillError.cipherUnavailable }
    return item
  }

  func ownership(access: NativeBitwardenFillAccess, organizationID: UUID?) throws
    -> NativeBitwardenFillOwnership
  {
    guard let accepted, accepted.access == access else {
      throw NativeBitwardenFillError.staleAccess
    }
    guard let organizationID else { return .personal }
    guard accepted.organizationIDs.contains(organizationID) else {
      throw NativeBitwardenFillError.organizationUnsupported
    }
    return .organization(organizationID)
  }

  func validate(_ access: NativeBitwardenFillAccess) throws {
    guard accepted?.access == access else { throw NativeBitwardenFillError.staleAccess }
  }
}

enum NativeBitwardenFillURIMode: Equatable, Sendable {
  case host, never, unsupported
}

struct NativeBitwardenFillURI: Sendable {
  let value: String?
  let mode: NativeBitwardenFillURIMode
}

/// Transient decrypted fields, never stored by access state.
struct NativeBitwardenFillCandidate: Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  let id: UUID?
  let organization: Bool
  var organizationID: UUID? = nil
  let login: Bool
  let deleted: Bool
  let archived: Bool
  let partial: Bool
  let viewPassword: Bool
  let reprompt: Bool
  let username: String?
  let password: String?
  let uris: [NativeBitwardenFillURI]
  var description: String { "NativeBitwardenFillCandidate(<redacted>)" }
  var debugDescription: String { description }
}

enum NativeBitwardenFillOwnership: Equatable, Sendable {
  case personal
  case organization(UUID)
}

enum NativeBitwardenFillPolicy {
  static func credential(
    from candidate: NativeBitwardenFillCandidate, id: UUID, origin: PasswordFillOrigin,
    ownership: NativeBitwardenFillOwnership = .personal
  ) throws -> NativeBitwardenFillCredential {
    switch ownership {
    case .personal:
      guard !candidate.organization, candidate.organizationID == nil else {
        throw NativeBitwardenFillError.organizationUnsupported
      }
    case .organization(let id):
      guard candidate.organization, candidate.organizationID == id else {
        throw NativeBitwardenFillError.ineligibleCipher
      }
    }
    guard candidate.id == id, candidate.login, !candidate.deleted, !candidate.archived,
      !candidate.partial, candidate.viewPassword,
      let username = candidate.username, !username.isEmpty,
      let password = candidate.password, !password.isEmpty
    else { throw NativeBitwardenFillError.ineligibleCipher }
    guard !candidate.reprompt else { throw NativeBitwardenFillError.repromptRequired }

    // Host mode compares host and effective port. Stored paths do not participate.
    if candidate.uris.contains(where: { $0.mode == .host && hostOrigin($0.value) == origin }) {
      return NativeBitwardenFillCredential(username: username, password: password)
    }
    if candidate.uris.contains(where: { $0.mode == .unsupported }) {
      throw NativeBitwardenFillError.unsupportedMatch
    }
    throw NativeBitwardenFillError.noMatchingURI
  }

  private static func hostOrigin(_ uri: String?) -> PasswordFillOrigin? {
    guard let uri, let parts = URLComponents(string: uri),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      let host = parts.percentEncodedHost?.lowercased(), !host.isEmpty,
      parts.url != nil, let separator = uri.range(of: "://"),
      parts.port.map({ (1...65535).contains($0) }) ?? true
    else { return nil }
    let authority = uri[separator.upperBound...].prefix { !"/?#".contains($0) }.lowercased()
    guard authority == host + (parts.port.map { ":\($0)" } ?? "") else { return nil }
    let port = parts.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
    return PasswordFillOrigin("https://" + host + port)
  }
}

/// The isolated owner supplies encrypted lookup, decryption, and revocation check.
enum NativeBitwardenFillLookup {
  static func credential<Item: Sendable>(
    isolation: isolated any Actor, id: UUID, origin: PasswordFillOrigin,
    item: () throws -> Item,
    decrypt: (Item) async throws -> NativeBitwardenFillCandidate,
    ownership: (Item) throws -> NativeBitwardenFillOwnership = { _ in .personal },
    validate: () throws -> Void
  ) async throws -> NativeBitwardenFillCredential {
    let encrypted = try item()
    let owner = try ownership(encrypted)
    try Task.checkCancellation()
    let candidate: NativeBitwardenFillCandidate
    do {
      candidate = try await decrypt(encrypted)
    } catch {
      try validate()
      throw error
    }
    try Task.checkCancellation()
    try validate()
    return try NativeBitwardenFillPolicy.credential(
      from: candidate, id: id, origin: origin, ownership: owner)
  }
}
