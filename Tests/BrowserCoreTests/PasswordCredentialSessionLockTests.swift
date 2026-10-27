import Darwin
import Foundation
import Testing

@testable import BrowserCore

@Suite struct PasswordCredentialSessionLockTests {
  private func binding() -> PasswordAuthenticationBinding {
    PasswordAuthenticationBinding(
      profileID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
      vaultID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
      accountID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
      authority: URL(string: "https://vault.example")!)
  }

  private func root() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return path
  }

  @Test func participatingProcessesContendAndExitReleasesLock() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    var lease: PasswordCredentialSessionLock? = try .acquire(
      service: "synthetic", binding: binding(), applicationSupport: directory)
    #expect(throws: PasswordCredentialSessionLock.Error.inUse) {
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic", binding: binding(), applicationSupport: directory)
    }
    let lockDirectory = directory.appending(path: "ArcusisBrowserCredentialLocks")
    let files = try FileManager.default.contentsOfDirectory(atPath: lockDirectory.path)
    #expect(files.count == 1)
    let lockFile = lockDirectory.appending(path: try #require(files.first))
    lease = nil
    _ = lease

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    child.arguments = [
      "-c",
      """
      import fcntl, os, sys
      fd = os.open(sys.argv[1], os.O_RDWR)
      fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
      os.write(fd, b'partial-marker')
      os.fsync(fd)
      print('ready', flush=True)
      sys.stdin.buffer.read(1)
      os._exit(0)
      """, lockFile.path,
    ]
    let input = Pipe()
    let output = Pipe()
    child.standardInput = input
    child.standardOutput = output
    child.standardError = Pipe()
    let env = ProcessInfo.processInfo.environment
    child.environment = [
      "PATH": "/usr/bin:/bin", "HOME": env["HOME"] ?? "",
      "TMPDIR": env["TMPDIR"] ?? "/tmp",
    ]
    try child.run()
    defer {
      try? input.fileHandleForWriting.close()
      if child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
    }
    let ready = try #require(try output.fileHandleForReading.read(upToCount: 6))
    #expect(ready == Data("ready\n".utf8))
    #expect(throws: PasswordCredentialSessionLock.Error.inUse) {
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic", binding: binding(), applicationSupport: directory)
    }
    try input.fileHandleForWriting.write(contentsOf: Data([0]))
    child.waitUntilExit()
    #expect(child.terminationStatus == 0)
    var afterExit: PasswordCredentialSessionLock? = try .acquire(
      service: "synthetic", binding: binding(), applicationSupport: directory)
    #expect(try afterExit?.hasPendingRotation() == true)
    try afterExit?.clearPendingRotation()
    afterExit = nil
  }

  @Test func failedDirectoryFlushRejectsLeaseWithoutLeavingLockHeld() throws {
    for failure in 1...2 {
      let directory = try root()
      defer { try? FileManager.default.removeItem(at: directory) }
      var calls = 0
      #expect(throws: PasswordCredentialSessionLock.Error.unavailable) {
        try PasswordCredentialSessionLock.acquire(
          service: "synthetic", binding: binding(), applicationSupport: directory,
          flushDirectory: { fd in
            calls += 1
            return calls == failure ? -1 : Darwin.fsync(fd)
          })
      }
      #expect(calls == failure)
      var lease: PasswordCredentialSessionLock? = try .acquire(
        service: "synthetic", binding: binding(), applicationSupport: directory)
      #expect(lease != nil)
      lease = nil
    }
  }

  @Test func rejectsFifoLockInodeWithoutBlocking() throws {
    let source = try root()
    let hostile = try root()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: hostile)
    }
    var lease: PasswordCredentialSessionLock? = try .acquire(
      service: "synthetic", binding: binding(), applicationSupport: source)
    #expect(lease != nil)
    let sourceLocks = source.appending(path: "ArcusisBrowserCredentialLocks")
    let name = try #require(FileManager.default.contentsOfDirectory(atPath: sourceLocks.path).first)
    lease = nil
    let hostileLocks = hostile.appending(path: "ArcusisBrowserCredentialLocks")
    try FileManager.default.createDirectory(
      at: hostileLocks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(mkfifo(hostileLocks.appending(path: name).path, mode_t(0o600)) == 0)
    #expect(throws: PasswordCredentialSessionLock.Error.unsafePath) {
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic", binding: binding(), applicationSupport: hostile)
    }
  }

  @Test func rejectsHardlinkedLockFileAndUnsafeDirectoryPermissions() throws {
    let source = try root()
    let hostile = try root()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: hostile)
    }
    var lease: PasswordCredentialSessionLock? = try .acquire(
      service: "synthetic", binding: binding(), applicationSupport: source)
    #expect(lease != nil)
    let sourceLocks = source.appending(path: "ArcusisBrowserCredentialLocks")
    let name = try #require(FileManager.default.contentsOfDirectory(atPath: sourceLocks.path).first)
    lease = nil
    let hostileLocks = hostile.appending(path: "ArcusisBrowserCredentialLocks")
    try FileManager.default.createDirectory(
      at: hostileLocks, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let target = hostile.appending(path: "target")
    try Data().write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    #expect(Darwin.link(target.path, hostileLocks.appending(path: name).path) == 0)
    #expect(throws: PasswordCredentialSessionLock.Error.unsafePath) {
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic", binding: binding(), applicationSupport: hostile)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o777], ofItemAtPath: hostileLocks.path)
    #expect(throws: PasswordCredentialSessionLock.Error.unsafePath) {
      try PasswordCredentialSessionLock.acquire(
        service: "other", binding: binding(), applicationSupport: hostile)
    }
  }

  @Test func pendingMarkerSurvivesLeaseReleaseUntilExplicitClear() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    var first: PasswordCredentialSessionLock? = try .acquire(
      service: "synthetic", binding: binding(), applicationSupport: directory)
    #expect(try first?.hasPendingRotation() == false)
    try first?.markPendingRotation(revision: 7)
    first = nil
    var next: PasswordCredentialSessionLock? = try .acquire(
      service: "synthetic", binding: binding(), applicationSupport: directory)
    #expect(try next?.hasPendingRotation() == true)
    try next?.clearPendingRotation()
    #expect(try next?.hasPendingRotation() == false)
    next = nil
  }

  @Test func rejectsSymlinkAndUnsafeDirectory() throws {
    let directory = try root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target")
    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let link = directory.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: PasswordCredentialSessionLock.Error.unsafePath) {
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic", binding: binding(), applicationSupport: link)
    }
    let lockDirectory = directory.appending(path: "ArcusisBrowserCredentialLocks")
    try FileManager.default.createSymbolicLink(at: lockDirectory, withDestinationURL: target)
    #expect(throws: PasswordCredentialSessionLock.Error.unsafePath) {
      try PasswordCredentialSessionLock.acquire(
        service: "synthetic", binding: binding(), applicationSupport: directory)
    }
  }
}
