import CryptoKit
import Darwin
import Foundation

/// Advisory lock shared by participating browser processes for one credential binding.
/// The lock file must never be removed while another process may hold its inode.
public final class PasswordCredentialSessionLock: @unchecked Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case unavailable
    case unsafePath
    case inUse
  }

  private let descriptor: Int32
  private let identity: String
  private let flushFile: @Sendable (Int32) -> Int32
  private init(
    descriptor: Int32, identity: String, flushFile: @escaping @Sendable (Int32) -> Int32
  ) {
    self.descriptor = descriptor
    self.identity = identity
    self.flushFile = flushFile
  }

  func matches(service: String, binding: PasswordAuthenticationBinding) throws -> Bool {
    identity == (try Self.lockName(service: service, binding: binding))
  }

  private static func lockName(service: String, binding: PasswordAuthenticationBinding) throws
    -> String
  {
    guard !service.isEmpty, service.utf8.count <= 512 else { throw Error.unsafePath }
    let authority = try PasswordCredentialStore.canonicalAuthority(binding.authority)
    let fields = [
      service, binding.profileID.uuidString.lowercased(), binding.vaultID.uuidString.lowercased(),
      binding.accountID.uuidString.lowercased(), authority,
    ]
    let data = try JSONEncoder().encode(fields)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".lock"
  }
  deinit { Darwin.close(descriptor) }

  /// Nonempty marker means a rotating credential may have been consumed.
  /// Unknown or partial marker bytes are also treated as pending.
  public func hasPendingRotation() throws -> Bool {
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_size >= 0 else { throw Error.unavailable }
    return status.st_size != 0
  }

  public func markPendingRotation(revision: UInt64) throws {
    let marker = Array("v1 \(identity) \(revision) \(UUID().uuidString.lowercased())\n".utf8)
    guard marker.count <= 256 else { throw Error.unavailable }
    let written = marker.withUnsafeBytes { bytes in
      Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
    }
    guard written == marker.count, ftruncate(descriptor, off_t(marker.count)) == 0,
      flushFile(descriptor) == 0
    else { throw Error.unavailable }
  }

  public func clearPendingRotation() throws {
    guard ftruncate(descriptor, 0) == 0, flushFile(descriptor) == 0 else { throw Error.unavailable }
  }

  public static func acquire(
    service: String, binding: PasswordAuthenticationBinding
  ) throws -> PasswordCredentialSessionLock {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { throw Error.unavailable }
    return try acquire(service: service, binding: binding, applicationSupport: support)
  }

  static func acquire(
    service: String, binding: PasswordAuthenticationBinding, applicationSupport: URL,
    flushDirectory: (Int32) -> Int32 = { Darwin.fsync($0) },
    flushFile: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
  ) throws -> PasswordCredentialSessionLock {
    let name = try lockName(service: service, binding: binding)

    let parent = Darwin.open(
      applicationSupport.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parent >= 0 else { throw Error.unsafePath }
    defer { Darwin.close(parent) }
    var parentStat = stat()
    guard fstat(parent, &parentStat) == 0, parentStat.st_mode & S_IFMT == S_IFDIR,
      parentStat.st_uid == geteuid(), parentStat.st_mode & 0o022 == 0
    else { throw Error.unsafePath }
    let directoryName = "ArcusisBrowserCredentialLocks"
    if mkdirat(parent, directoryName, mode_t(0o700)) != 0 && errno != EEXIST {
      throw Error.unavailable
    }
    let directory = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw Error.unsafePath }
    defer { Darwin.close(directory) }
    var directoryStat = stat()
    guard fstat(directory, &directoryStat) == 0, directoryStat.st_mode & S_IFMT == S_IFDIR,
      directoryStat.st_uid == geteuid(), directoryStat.st_mode & 0o777 == 0o700
    else { throw Error.unsafePath }
    guard flushDirectory(parent) == 0 else { throw Error.unavailable }
    let fd = openat(
      directory, name, O_RDWR | O_CREAT | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw Error.unsafePath }
    var keep = false
    defer { if !keep { Darwin.close(fd) } }
    var fileStat = stat()
    guard fstat(fd, &fileStat) == 0, fileStat.st_mode & S_IFMT == S_IFREG,
      fileStat.st_uid == geteuid(), fileStat.st_nlink == 1, fileStat.st_mode & 0o777 == 0o600
    else { throw Error.unsafePath }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK || errno == EAGAIN { throw Error.inUse }
      throw Error.unavailable
    }
    guard flushDirectory(directory) == 0 else { throw Error.unavailable }
    keep = true
    return PasswordCredentialSessionLock(descriptor: fd, identity: name, flushFile: flushFile)
  }
}
