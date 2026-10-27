import Foundation
import Testing

@testable import ArcusisBrowser

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK

  private actor CipherRepositoryCallbackGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      if released { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func release() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }

  @Suite struct NativeBitwardenCipherRepositoryTests {
    private func cipher(
      id: String, name: String = "2.synthetic-ciphertext", partialData: String? = nil,
      data: String? = nil
    ) -> Cipher {
      let date = Date(timeIntervalSince1970: 0)
      return Cipher(
        id: id, organizationId: nil, folderId: nil, collectionIds: [], key: nil,
        name: name, notes: nil, type: .login, login: nil, identity: nil, card: nil,
        secureNote: nil, sshKey: nil, bankAccount: nil, driversLicense: nil, passport: nil,
        favorite: false, reprompt: .none, organizationUseTotp: false, edit: true,
        permissions: nil, viewPassword: true, localData: nil, attachments: nil, fields: nil,
        passwordHistory: nil, creationDate: date, deletedDate: nil, revisionDate: date,
        archivedDate: nil, data: data, partialData: partialData)
    }

    private func id() -> String { UUID().uuidString.lowercased() }

    @Test func stagingRequiresAtomicAcceptanceAndRevocationIsPermanent() async throws {
      let old = NativeBitwardenCipherRepository()
      let itemID = id()
      let item = cipher(id: itemID)
      await #expect(throws: RepositoryError.self) { try await old.get(id: itemID) }
      await #expect(throws: RepositoryError.self) { try await old.set(id: itemID, value: item) }
      try old.acceptSnapshot([item])
      #expect(try await old.get(id: itemID) == item)
      #expect(throws: RepositoryError.self) { try old.acceptSnapshot([]) }
      old.revoke()
      await #expect(throws: RepositoryError.self) { try await old.get(id: itemID) }
      await #expect(throws: RepositoryError.self) { try await old.set(id: itemID, value: item) }
      #expect(throws: RepositoryError.self) { try old.acceptSnapshot([item]) }
      #expect(!String(reflecting: old).contains("synthetic-ciphertext"))
    }

    @Test func staleCallbacksCannotMutateSuccessor() async throws {
      let previous = NativeBitwardenCipherRepository()
      let successor = NativeBitwardenCipherRepository()
      let itemID = id()
      let old = cipher(id: itemID)
      let fresh = cipher(id: itemID, name: "2.new-ciphertext")
      #expect(previous.ownerID != successor.ownerID)
      try previous.acceptSnapshot([old])
      let gate = CipherRepositoryCallbackGate()
      let delayed = Task {
        await gate.wait()
        try await previous.set(id: itemID, value: old)
      }
      previous.revoke()
      try successor.acceptSnapshot([fresh])
      await gate.release()
      await #expect(throws: RepositoryError.self) { try await delayed.value }
      await #expect(throws: RepositoryError.self) { try await previous.removeAll() }
      #expect(try await successor.get(id: itemID) == fresh)
      successor.revoke()
    }

    @Test func invalidBulkOperationsLeavePriorSnapshotIntact() async throws {
      let repository = NativeBitwardenCipherRepository()
      let first = id()
      let second = id()
      let original = cipher(id: first)
      try repository.acceptSnapshot([original])
      let invalid = cipher(id: id())
      await #expect(throws: RepositoryError.self) {
        try await repository.setBulk(values: [
          first: cipher(id: first, name: "2.changed"), second: invalid,
        ])
      }
      #expect(try await repository.list() == [original])
      let opaque = cipher(id: second, data: "{\"unknown\":\"untrusted\"}")
      await #expect(throws: RepositoryError.self) {
        try await repository.set(id: second, value: opaque)
      }
      #expect(try await repository.list() == [original])
      await #expect(throws: RepositoryError.self) {
        try await repository.removeBulk(keys: [first, "invalid"])
      }
      #expect(try await repository.get(id: first) == original)
      await #expect(throws: RepositoryError.self) {
        try await repository.get(id: first.uppercased())
      }
      let restricted = cipher(id: second, partialData: "{\"unknown\":\"untrusted\"}")
      await #expect(throws: RepositoryError.self) {
        try await repository.setBulk(values: [
          first: cipher(id: first, name: "2.changed"), second: restricted,
        ])
      }
      #expect(try await repository.list() == [original])
      repository.revoke()
    }

    @Test func sizeCountAndDuplicateLimitsFailClosed() async throws {
      let repository = NativeBitwardenCipherRepository()
      let first = id()
      let original = cipher(id: first)
      #expect(throws: RepositoryError.self) { try repository.acceptSnapshot([original, original]) }
      try repository.acceptSnapshot([original])
      let huge = cipher(
        id: first,
        name: String(repeating: "x", count: NativeBitwardenCipherRepository.maximumCipherBytes))
      await #expect(throws: RepositoryError.self) {
        try await repository.set(id: first, value: huge)
      }
      #expect(try await repository.get(id: first) == original)
      var tooMany: [String: Cipher] = [:]
      for _ in 0...NativeBitwardenCipherRepository.maximumCipherCount {
        let itemID = id()
        tooMany[itemID] = cipher(id: itemID)
      }
      await #expect(throws: RepositoryError.self) { try await repository.setBulk(values: tooMany) }
      #expect(try await repository.list() == [original])
      repository.revoke()
    }

    @Test func bulkOperationsPublishWholeUpdate() async throws {
      let repository = NativeBitwardenCipherRepository()
      let first = id()
      let second = id()
      try repository.acceptSnapshot([cipher(id: first)])
      let replacement = cipher(id: first, name: "2.replacement")
      let added = cipher(id: second)
      try await repository.setBulk(values: [first: replacement, second: added])
      #expect(try await repository.get(id: first) == replacement)
      #expect(try await repository.has(id: second))
      try await repository.removeBulk(keys: [first, second])
      #expect(try await repository.list().isEmpty)
      repository.revoke()
    }

    @Test func aggregateByteLimitDoesNotPartiallyCommit() async throws {
      let repository = NativeBitwardenCipherRepository()
      let first = id()
      let original = cipher(id: first)
      try repository.acceptSnapshot([original])
      let large = String(repeating: "x", count: 900_000)
      var updates: [String: Cipher] = [:]
      for _ in 0..<20 {
        let itemID = id()
        updates[itemID] = cipher(id: itemID, name: large)
      }
      await #expect(throws: RepositoryError.self) { try await repository.setBulk(values: updates) }
      #expect(try await repository.list() == [original])
      repository.revoke()
    }
  }
#endif
