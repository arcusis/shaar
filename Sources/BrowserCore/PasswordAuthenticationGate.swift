import Foundation

/// Stable host ownership context for a password authentication attempt.
public struct PasswordAuthenticationBinding: Equatable, Sendable {
  public let profileID: UUID
  public let vaultID: UUID
  public let accountID: UUID
  public let authority: URL

  public init(profileID: UUID, vaultID: UUID, accountID: UUID, authority: URL) {
    self.profileID = profileID
    self.vaultID = vaultID
    self.accountID = accountID
    self.authority = authority
  }
}

/// Owns publication rights for one Profile/vault/account/authority context.
/// SDK work may outlive its host attempt; always call `commit` before publishing.
@MainActor
public final class PasswordAuthenticationGate {
  public struct Attempt: Equatable, Sendable {
    fileprivate let ownerID: UUID
    fileprivate let nonce: UUID
    fileprivate let binding: PasswordAuthenticationBinding
  }

  private let ownerID = UUID()
  private var binding: PasswordAuthenticationBinding
  private var enabled: Bool
  private var activeAttempt: Attempt?

  public init(binding: PasswordAuthenticationBinding, enabled: Bool = true) {
    self.binding = binding
    self.enabled = enabled
  }

  /// Starts a new attempt and revokes publication rights from any prior one.
  public func beginAttempt() -> Attempt? {
    guard enabled else { return nil }
    let attempt = Attempt(ownerID: ownerID, nonce: UUID(), binding: binding)
    activeAttempt = attempt
    return attempt
  }

  /// Invalidates only this attempt; late cleanup cannot revoke its successor.
  public func invalidate(_ attempt: Attempt) {
    if activeAttempt == attempt { activeAttempt = nil }
  }

  public func setEnabled(_ value: Bool) {
    enabled = value
    if !value { activeAttempt = nil }
  }

  /// Context changes revoke outstanding attempts; identical binding preserves them.
  public func rebind(to newBinding: PasswordAuthenticationBinding) {
    guard binding != newBinding else { return }
    binding = newBinding
    activeAttempt = nil
  }

  /// Consumes ownership before synchronous publication, allowing safe reentrancy.
  @discardableResult
  public func commit(_ attempt: Attempt, publish: () -> Void) -> Bool {
    guard enabled, attempt.ownerID == ownerID, attempt.binding == binding,
      activeAttempt == attempt
    else { return false }
    activeAttempt = nil
    publish()
    return true
  }
}
