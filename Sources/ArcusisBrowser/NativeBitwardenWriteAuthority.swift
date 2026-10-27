import BrowserCore
import Foundation
import Synchronization

/// Identifiers only. This authority does not establish browser ownership or consent.
final class NativeBitwardenWriteAuthority: Sendable {
  struct Binding: Equatable, Sendable {
    let owner: PasswordAuthenticationBinding
    let identityURL: URL
    let apiURL: URL
    let access: NativeBitwardenFillAccess
  }

  struct Ticket: Equatable, Sendable {
    fileprivate let epoch: UUID
  }

  struct Lease: Equatable, Sendable {
    let binding: Binding
    fileprivate let epoch: UUID
  }

  private struct State: Sendable {
    var epoch = UUID()
    var accepted: Lease?
  }
  private let state = Mutex(State())

  /// Synchronous linearization point for owner, snapshot, or session changes.
  @discardableResult
  func revoke() -> Ticket {
    state.withLock { state in
      state.epoch = UUID()
      state.accepted = nil
      return Ticket(epoch: state.epoch)
    }
  }

  /// A delayed sync cannot publish after any intervening revoke or adoption.
  func adopt(ticket: Ticket, binding: Binding) -> Lease? {
    state.withLock { state in
      guard state.epoch == ticket.epoch, state.accepted == nil else { return nil }
      let lease = Lease(binding: binding, epoch: ticket.epoch)
      state.accepted = lease
      return lease
    }
  }

  func isCurrent(_ lease: Lease) -> Bool {
    state.withLock { $0.accepted == lease }
  }

  /// Failure of an older adoption cannot revoke a newer accepted snapshot.
  func revoke(_ lease: Lease) {
    state.withLock { state in
      guard state.accepted == lease else { return }
      state.epoch = UUID()
      state.accepted = nil
    }
  }

  /// Claim and revoke are serialized; a claimed write is already authorized.
  func claim(_ lease: Lease) -> Bool {
    state.withLock { state in
      guard state.accepted == lease else { return false }
      state.accepted = nil
      state.epoch = UUID()
      return true
    }
  }
}
