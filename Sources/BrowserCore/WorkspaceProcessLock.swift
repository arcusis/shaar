import Darwin
import Foundation

public enum WorkspaceLockError: Error, LocalizedError {
  case inUse, invalidFile

  public var errorDescription: String? {
    switch self {
    case .inUse: "Another Arcusis Browser process is using this workspace."
    case .invalidFile: "The workspace lock file is invalid."
    }
  }
}

/// Keep alive through engine shutdown. Never unlink the file while another descriptor may use its inode.
public final class WorkspaceProcessLock {
  private let descriptor: Int32

  public init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = directory.appending(path: "workspace.lock").path
    let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var keep = false
    defer { if !keep { Darwin.close(fd) } }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
      throw WorkspaceLockError.invalidFile
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw WorkspaceLockError.inUse }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard fchmod(fd, mode_t(0o600)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    descriptor = fd
    keep = true
  }

  deinit { Darwin.close(descriptor) }
}
