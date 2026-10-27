import BrowserCore
import Foundation

/// Internal caller must independently validate browser ownership and consent.
struct NativeBitwardenWriteInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let username: String
  let password: String
  let name: String

  var description: String { "NativeBitwardenWriteInput(<redacted>)" }
  var debugDescription: String { description }

  func validate() throws {
    guard !username.isEmpty,
      username.utf8.count <= NativeBitwardenVaultSnapshot.maximumUsernameBytes,
      !password.isEmpty, password.utf8.count <= 16_384,
      !name.isEmpty, name.utf8.count <= NativeBitwardenVaultSnapshot.maximumNameBytes
    else { throw NativeBitwardenWriteError.invalidInput }
  }
}

struct NativeBitwardenWriteReceipt: Sendable {
  let cipherID: UUID
  let revision: Date
}

enum NativeBitwardenWriteError: Error, Equatable, Sendable {
  case invalidInput
  case staleAccess
  case operationInProgress
  case ineligibleCipher
  case staleRevision
  case sdkUpdateUnavailable
  /// Dispatch occurred; server outcome is unknown and must be reconciled by sync.
  case unconfirmed
}

protocol NativeBitwardenWriteBackend: Sendable {
  func createLogin(
    access: NativeBitwardenFillAccess, context: PasswordFillContext,
    input: NativeBitwardenWriteInput
  ) async throws -> NativeBitwardenWriteReceipt
  func updateLogin(
    access: NativeBitwardenFillAccess, context: PasswordFillContext, cipherID: UUID,
    revision: Date, input: NativeBitwardenWriteInput
  ) async throws -> NativeBitwardenWriteReceipt
}

/// An in-memory lookup key, not evidence of browser ownership or user consent.
struct NativeBitwardenStrictUpdateHandle: Sendable, Equatable {
  let id: UUID
  init() { id = UUID() }
}

struct NativeBitwardenStrictUpdateInput: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  let username: String?
  let password: String
  var description: String { "NativeBitwardenStrictUpdateInput(<redacted>)" }
  var debugDescription: String { description }

  func validate() throws {
    guard
      username.map({ $0.utf8.count <= NativeBitwardenVaultSnapshot.maximumUsernameBytes }) ?? true,
      !password.isEmpty, password.utf8.count <= 16_384
    else { throw NativeBitwardenWriteError.invalidInput }
  }
}

/// Internal plumbing only. The caller must establish and revalidate ownership and consent.
protocol NativeBitwardenStrictWriteBackend: Sendable {
  func adoptStrictWriteAuthority(
    _ admission: NativeBitwardenWriteAdmission
  ) async throws
  func prepareStrictUpdate(
    access: NativeBitwardenFillAccess, context: PasswordFillContext, cipherID: UUID
  ) async throws -> NativeBitwardenStrictUpdateHandle
  func cancelStrictUpdate(sessionID: UUID, handle: NativeBitwardenStrictUpdateHandle) async
  func strictUpdate(
    access: NativeBitwardenFillAccess, context: PasswordFillContext,
    handle: NativeBitwardenStrictUpdateHandle, input: NativeBitwardenStrictUpdateInput
  ) async throws
}
