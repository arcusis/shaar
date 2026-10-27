import Darwin
import Foundation
import XCTest

@testable import BrowserCore

private final class DuplicateReleaseWeakLease {
  weak var value: PasswordCredentialSessionLock?

  init(_ value: PasswordCredentialSessionLock) {
    self.value = value
  }
}

final class PasswordCredentialDuplicateReleaseTests: XCTestCase {
  private func binding() -> PasswordAuthenticationBinding {
    PasswordAuthenticationBinding(
      profileID: UUID(), vaultID: UUID(), accountID: UUID(),
      authority: URL(string: "https://synthetic.example")!)
  }

  private func releaseWithDuplicate(
    _ directory: URL, _ binding: PasswordAuthenticationBinding
  ) throws -> (Int32, DuplicateReleaseWeakLease) {
    let lease = try PasswordCredentialSessionLock.acquire(
      service: "synthetic-duplicate-release", binding: binding, applicationSupport: directory)
    try lease.markPendingRotation(revision: 7)
    let weakLease = DuplicateReleaseWeakLease(lease)
    let descriptor = try XCTUnwrap(
      Mirror(reflecting: lease).children.first { $0.label == "descriptor" }?.value as? Int32)
    let duplicate = Darwin.dup(descriptor)
    guard duplicate >= 0 else {
      throw NSError(domain: "SyntheticDuplicate", code: Int(errno))
    }
    return (duplicate, weakLease)
  }

  func testReleaseWithOwnedDuplicatePreservesPendingMarker() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "synthetic-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = binding()
    let (duplicate, weakLease) = try releaseWithDuplicate(directory, owner)
    defer { Darwin.close(duplicate) }
    XCTAssertNil(weakLease.value, "Original lease must deinitialize before reacquisition")
    let replacement = try PasswordCredentialSessionLock.acquire(
      service: "synthetic-duplicate-release", binding: owner, applicationSupport: directory)
    XCTAssertTrue(try replacement.hasPendingRotation())
    try replacement.clearPendingRotation()
    XCTAssertFalse(try replacement.hasPendingRotation())
    withExtendedLifetime(replacement) {}
  }

  func testLivingLeaseStillExcludesIndependentOpen() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "synthetic-lock-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = binding()
    let lease = try PasswordCredentialSessionLock.acquire(
      service: "synthetic-contention", binding: owner, applicationSupport: directory)
    XCTAssertThrowsError(
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic-contention", binding: owner, applicationSupport: directory)
    ) { error in
      XCTAssertEqual(error as? PasswordCredentialSessionLock.Error, .inUse)
    }
    withExtendedLifetime(lease) {}
  }
}
