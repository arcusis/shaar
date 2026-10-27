import Foundation
import Synchronization

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK

  /// One SDK session generation owns one in-memory encrypted repository.
  final class NativeBitwardenCipherRepository: CipherRepository, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
  {
    static let maximumCipherCount = NativeBitwardenVaultSnapshot.maximumCipherCount
    static let maximumCipherBytes = 1_048_576
    static let maximumTotalBytes = NativeBitwardenVaultSnapshot.maximumSnapshotMetadataBytes

    private struct Entry: Sendable {
      let cipher: Cipher
      let bytes: Int
    }
    private enum Phase: Sendable { case staging, active, revoked }
    private struct State: Sendable {
      var phase: Phase = .staging
      var entries: [String: Entry] = [:]
      var bytes = 0
    }

    let ownerID = UUID()
    private let state = Mutex(State())
    var description: String { "NativeBitwardenCipherRepository(<redacted>)" }
    var debugDescription: String { description }

    init() {}

    /// Revocation is synchronous and permanent, including for callbacks already queued by SDK.
    func revoke() {
      state.withLock { value in
        value.phase = .revoked
        value.entries.removeAll(keepingCapacity: false)
        value.bytes = 0
      }
    }

    /// Activates only a complete, validated encrypted sync snapshot.
    func acceptSnapshot(_ ciphers: [Cipher]) throws {
      guard ciphers.count <= Self.maximumCipherCount else { throw Self.failure() }
      var entries: [String: Entry] = [:]
      var bytes = 0
      for cipher in ciphers {
        guard let id = cipher.id, entries[id] == nil else { throw Self.failure() }
        let entry = try Self.checkedEntry(id: id, cipher: cipher)
        guard entry.bytes <= Self.maximumTotalBytes - bytes else { throw Self.failure() }
        entries[id] = entry
        bytes += entry.bytes
      }
      try state.withLock { value in
        guard value.phase == .staging else { throw Self.failure() }
        value.entries = entries
        value.bytes = bytes
        value.phase = .active
      }
    }

    func get(id: String) async throws -> Cipher? {
      try Self.requireID(id)
      return try state.withLock { value in
        guard value.phase == .active else { throw Self.failure() }
        return value.entries[id]?.cipher
      }
    }

    func list() async throws -> [Cipher] {
      try state.withLock { value in
        guard value.phase == .active else { throw Self.failure() }
        return value.entries.keys.sorted().compactMap { value.entries[$0]?.cipher }
      }
    }

    func set(id: String, value: Cipher) async throws {
      try await setBulk(values: [id: value])
    }

    func setBulk(values: [String: Cipher]) async throws {
      guard values.count <= Self.maximumCipherCount else { throw Self.failure() }
      var updates: [String: Entry] = [:]
      for (id, cipher) in values { updates[id] = try Self.checkedEntry(id: id, cipher: cipher) }
      try state.withLock { value in
        guard value.phase == .active else { throw Self.failure() }
        var bytes = value.bytes
        var count = value.entries.count
        for id in updates.keys {
          if let old = value.entries[id] { bytes -= old.bytes } else { count += 1 }
        }
        guard count <= Self.maximumCipherCount else { throw Self.failure() }
        for entry in updates.values {
          guard entry.bytes <= Self.maximumTotalBytes - bytes else { throw Self.failure() }
          bytes += entry.bytes
        }
        value.entries.merge(updates) { _, new in new }
        value.bytes = bytes
      }
    }

    func remove(id: String) async throws { try await removeBulk(keys: [id]) }

    func removeBulk(keys: [String]) async throws {
      guard keys.count <= Self.maximumCipherCount else { throw Self.failure() }
      for id in keys { try Self.requireID(id) }
      try state.withLock { value in
        guard value.phase == .active else { throw Self.failure() }
        for id in keys {
          if let removed = value.entries.removeValue(forKey: id) { value.bytes -= removed.bytes }
        }
      }
    }

    func removeAll() async throws {
      try state.withLock { value in
        guard value.phase == .active else { throw Self.failure() }
        value.entries.removeAll(keepingCapacity: false)
        value.bytes = 0
      }
    }

    func has(id: String) async throws -> Bool {
      try Self.requireID(id)
      return try state.withLock { value in
        guard value.phase == .active else { throw Self.failure() }
        return value.entries[id] != nil
      }
    }

    private static func requireID(_ id: String) throws {
      guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
        throw failure()
      }
    }

    private static func checkedEntry(id: String, cipher: Cipher) throws -> Entry {
      try requireID(id)
      guard cipher.id == id, cipher.partialData == nil, cipher.data == nil else { throw failure() }
      // SDK encoding covers every field without maintaining a parallel model.
      // This bounds retained serialized payload, not peak allocation or RSS.
      var encoded: [UInt8] = []
      FfiConverterTypeCipher.write(cipher, into: &encoded)
      guard encoded.count <= maximumCipherBytes else { throw failure() }
      return Entry(cipher: cipher, bytes: encoded.count)
    }

    private static func failure() -> RepositoryError { .Internal("Cipher repository unavailable") }
  }
#endif
