// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

public enum WorkspaceLockError: Error, LocalizedError {
  case inUse, invalidFile

  public var errorDescription: String? {
    switch self {
    case .inUse:
      BrowserLocalization.format(
        "Another %@ process is using this workspace.", arguments: [.string(ProductIdentity.name)])
    case .invalidFile: BrowserLocalization.string("The workspace lock file is invalid.")
    }
  }
}

/// Keep alive through engine shutdown. Never unlink the file while another descriptor may use its inode.
public final class WorkspaceProcessLock {
  private var descriptor: Int32 = -1

  public init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let path = directory.appending(path: "workspace.lock").path
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else {
      let openError = errno
      throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
    }
    var keep = false
    defer { if !keep { Darwin.close(fd) } }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
      throw WorkspaceLockError.invalidFile
    }
    if let lockError = Self.exclusiveLockError(fd) {
      if lockError == EWOULDBLOCK { throw WorkspaceLockError.inUse }
      throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
    }
    guard fchmod(fd, mode_t(0o600)) == 0 else {
      let modeError = errno
      throw POSIXError(POSIXErrorCode(rawValue: modeError) ?? .EIO)
    }
    descriptor = fd
    keep = true
  }

  /// Close the descriptor before the object is destroyed so the same file can be locked again.
  public func release() {
    let fd = descriptor
    guard fd >= 0 else { return }
    descriptor = -1
    Darwin.close(fd)
  }

  deinit { release() }

  private static func exclusiveLockError(_ fd: Int32) -> Int32? {
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return nil }
    return errno
  }
}
