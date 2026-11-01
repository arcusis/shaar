// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A saved model that must pass its own invariants before it is written or restored.
public protocol ValidatedSnapshot: Codable, Sendable {
  func validate() throws
}

extension BrowserSession: ValidatedSnapshot {}
extension BrowserWorkspace: ValidatedSnapshot {}

/// A JSON snapshot that survives a crash, SIGKILL or power loss.
///
/// Each save is flushed to permanent storage before an atomic rename, and the replaced file is
/// kept as a last-known-good backup. A primary that fails to decode or validate is moved aside
/// and the backup is restored, so a damaged file never becomes an empty session.
public struct SnapshotFile<Value: ValidatedSnapshot>: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public var backupURL: URL { url.appendingPathExtension("backup") }
  public var damagedURL: URL { url.appendingPathExtension("damaged") }

  /// Returns nil when neither the primary nor the backup exists. Throws the primary's error when
  /// no valid backup can replace it; both files are then left untouched.
  public func load() throws -> Value? {
    do {
      if let value = try Self.read(url) { return value }
    } catch {
      guard let backup = try? Self.read(backupURL) else { throw error }
      // The damaged primary must not rotate into the backup on the next save.
      try DurableFileWriter.move(url, to: damagedURL)
      return backup
    }
    return try Self.read(backupURL)
  }

  /// Reads only the primary file, without falling back or moving anything. For verification.
  public func loadPrimary() throws -> Value? { try Self.read(url) }

  public func save(_ value: Value) throws {
    try value.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try DurableFileWriter.replace(url, with: encoder.encode(value), backup: backupURL)
  }

  private static func read(_ url: URL) throws -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    try value.validate()
    return value
  }
}

/// POSIX file replacement with full device flushes. Owner-only permissions are set at creation.
enum DurableFileWriter {
  static func replace(_ url: URL, with data: Data, backup: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    removeStaleTemporaryFiles(of: url)
    let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
      try writeFlushed(data, to: temporary)
      try rotate(url, into: backup)
      try rename(temporary, to: url)
    } catch {
      unlink(temporary.path)
      throw error
    }
    try flushDirectory(directory)
  }

  static func move(_ source: URL, to destination: URL) throws {
    try rename(source, to: destination)
    try flushDirectory(source.deletingLastPathComponent())
  }

  /// One process owns the file and writes serially, so leftovers belong to a killed writer.
  private static func removeStaleTemporaryFiles(of url: URL) {
    let directory = url.deletingLastPathComponent()
    let prefix = ".\(url.lastPathComponent)."
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
      unlink(directory.appending(path: name).path)
    }
  }

  private static func writeFlushed(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixError() }
    defer { close(descriptor) }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw posixError() }
        offset += written
      }
    }
    try flush(descriptor)
  }

  /// The previous primary becomes the backup through a hard link, so a primary always exists.
  private static func rotate(_ url: URL, into backup: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let staged = backup.deletingLastPathComponent().appending(
      path: ".\(backup.lastPathComponent).\(UUID().uuidString).tmp")
    guard link(url.path, staged.path) == 0 else { throw posixError() }
    do {
      try rename(staged, to: backup)
    } catch {
      unlink(staged.path)
      throw error
    }
  }

  private static func rename(_ source: URL, to destination: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError() }
  }

  private static func flushDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError() }
    defer { close(descriptor) }
    try flush(descriptor)
  }

  /// F_FULLFSYNC reaches the storage device; fsync covers file systems that do not support it.
  private static func flush(_ descriptor: Int32) throws {
    guard fcntl(descriptor, F_FULLFSYNC) != 0 else { return }
    guard fsync(descriptor) == 0 else { throw posixError() }
  }

  private static func posixError() -> Error {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
