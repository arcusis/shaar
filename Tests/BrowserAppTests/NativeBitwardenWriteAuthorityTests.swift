import BrowserCore
import Foundation
import Synchronization
import XCTest

@testable import ArcusisBrowser

private final class AuthorityTestCounter: Sendable {
  let value = Mutex(0)
}

final class NativeBitwardenWriteAuthorityTests: XCTestCase {
  private func binding(profile: UUID = UUID(), account: UUID = UUID(), session: UUID = UUID())
    throws
    -> NativeBitwardenWriteAuthority.Binding
  {
    var state = NativeBitwardenFillAccessState<Int>(sessionID: session)
    let ticket = try state.beginSync()
    try state.publish(ticket: ticket, snapshot: .empty, items: [:])
    state.finishSync(ticket)
    return NativeBitwardenWriteAuthority.Binding(
      owner: PasswordAuthenticationBinding(
        profileID: profile, vaultID: UUID(), accountID: account,
        authority: URL(string: "https://authority.example")!),
      identityURL: URL(string: "https://identity.example")!,
      apiURL: URL(string: "https://api.example")!, access: try state.snapshot().access)
  }

  func testRevokeAndClaimRejectStaleAdoption() throws {
    let authority = NativeBitwardenWriteAuthority()
    let binding = try binding()
    let old = authority.revoke()
    let current = authority.revoke()
    XCTAssertNil(authority.adopt(ticket: old, binding: binding))
    let lease = try XCTUnwrap(authority.adopt(ticket: current, binding: binding))
    XCTAssertTrue(authority.isCurrent(lease))
    XCTAssertTrue(authority.claim(lease))
    XCTAssertFalse(authority.claim(lease))
    XCTAssertNil(authority.adopt(ticket: current, binding: binding))
    let next = authority.revoke()
    let renewed = try XCTUnwrap(authority.adopt(ticket: next, binding: binding))
    authority.revoke(lease)
    XCTAssertTrue(authority.isCurrent(renewed))
    authority.revoke()
    XCTAssertFalse(authority.claim(renewed))
    XCTAssertNil(authority.adopt(ticket: next, binding: binding))
  }

  func testIndependentOwnersAndExactBindings() throws {
    let first = NativeBitwardenWriteAuthority()
    let second = NativeBitwardenWriteAuthority()
    let a = try binding()
    let b = try binding()
    let firstLease = try XCTUnwrap(first.adopt(ticket: first.revoke(), binding: a))
    let secondLease = try XCTUnwrap(second.adopt(ticket: second.revoke(), binding: b))
    XCTAssertNotEqual(a.owner.profileID, b.owner.profileID)
    XCTAssertNotEqual(a.owner.accountID, b.owner.accountID)
    XCTAssertNotEqual(a.access.sessionID, b.access.sessionID)
    XCTAssertFalse(first.isCurrent(secondLease))
    first.revoke()
    XCTAssertFalse(first.claim(firstLease))
    XCTAssertTrue(second.claim(secondLease))
  }

  func testBindingSeparatesEveryOwnerAndSnapshotField() throws {
    let base = try binding()
    let owner = base.owner
    let differentSession = try binding().access
    var snapshotState = NativeBitwardenFillAccessState<Int>(sessionID: base.access.sessionID)
    let ticket = try snapshotState.beginSync()
    try snapshotState.publish(ticket: ticket, snapshot: .empty, items: [:])
    let differentSnapshot = try snapshotState.snapshot().access
    let owners = [
      PasswordAuthenticationBinding(
        profileID: UUID(), vaultID: owner.vaultID,
        accountID: owner.accountID, authority: owner.authority),
      PasswordAuthenticationBinding(
        profileID: owner.profileID, vaultID: UUID(),
        accountID: owner.accountID, authority: owner.authority),
      PasswordAuthenticationBinding(
        profileID: owner.profileID, vaultID: owner.vaultID,
        accountID: UUID(), authority: owner.authority),
      PasswordAuthenticationBinding(
        profileID: owner.profileID, vaultID: owner.vaultID,
        accountID: owner.accountID, authority: URL(string: "https://other.example")!),
    ]
    for other in owners {
      XCTAssertNotEqual(
        base,
        .init(
          owner: other, identityURL: base.identityURL,
          apiURL: base.apiURL, access: base.access))
    }
    XCTAssertNotEqual(
      base,
      .init(
        owner: owner, identityURL: URL(string: "https://other.example")!,
        apiURL: base.apiURL, access: base.access))
    XCTAssertNotEqual(
      base,
      .init(
        owner: owner, identityURL: base.identityURL,
        apiURL: URL(string: "https://other.example")!, access: base.access))
    XCTAssertNotEqual(
      base,
      .init(
        owner: owner, identityURL: base.identityURL,
        apiURL: base.apiURL, access: differentSession))
    XCTAssertNotEqual(
      base,
      .init(
        owner: owner, identityURL: base.identityURL,
        apiURL: base.apiURL, access: differentSnapshot))
  }

  func testConcurrentClaimHasOneWinner() throws {
    let authority = NativeBitwardenWriteAuthority()
    let lease = try XCTUnwrap(authority.adopt(ticket: authority.revoke(), binding: binding()))
    let wins = AuthorityTestCounter()
    let reads = AuthorityTestCounter()
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      if authority.isCurrent(lease) { reads.value.withLock { $0 += 1 } }
      if authority.claim(lease) { wins.value.withLock { $0 += 1 } }
    }
    XCTAssertEqual(wins.value.withLock { $0 }, 1)
    XCTAssertGreaterThanOrEqual(reads.value.withLock { $0 }, 1)
    XCTAssertFalse(authority.isCurrent(lease))
  }
}
