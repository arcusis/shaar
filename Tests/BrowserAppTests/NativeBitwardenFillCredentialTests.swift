import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif

private actor DeferredFillDecryptor {
  private var result: CheckedContinuation<NativeBitwardenFillCandidate, Never>?
  private var started: CheckedContinuation<Void, Never>?

  func decrypt(_ item: NativeBitwardenFillCandidate) async -> NativeBitwardenFillCandidate {
    await withCheckedContinuation { continuation in
      result = continuation
      started?.resume()
      started = nil
    }
  }

  func waitUntilStarted() async {
    if result != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func resolve(_ item: NativeBitwardenFillCandidate) {
    result?.resume(returning: item)
    result = nil
  }
}

private actor MemoryFillBackend {
  private var state: NativeBitwardenFillAccessState<NativeBitwardenFillCandidate>
  private let decryptor: DeferredFillDecryptor

  init(sessionID: UUID, decryptor: DeferredFillDecryptor) {
    state = NativeBitwardenFillAccessState(sessionID: sessionID)
    self.decryptor = decryptor
  }

  func beginSync() throws -> NativeBitwardenSyncTicket { try state.beginSync() }
  func finishSync(
    _ ticket: NativeBitwardenSyncTicket, id: UUID, item: NativeBitwardenFillCandidate,
    organizationIDs: Set<UUID> = []
  ) throws {
    defer { state.finishSync(ticket) }
    try state.publish(
      ticket: ticket, snapshot: .empty, items: [id: item], organizationIDs: organizationIDs)
  }
  func access() throws -> NativeBitwardenFillAccess { try state.snapshot().access }
  func lockOrDiscard() { _ = state.revoke() }

  func lookup(
    access: NativeBitwardenFillAccess, id: UUID, origin: PasswordFillOrigin
  ) async throws -> NativeBitwardenFillCredential {
    try await NativeBitwardenFillLookup.credential(
      isolation: self, id: id, origin: origin,
      item: {
        let item = try self.state.item(access: access, id: id)
        return (item, try self.state.ownership(access: access, organizationID: item.organizationID))
      },
      decrypt: { item in await self.decryptor.decrypt(item.0) },
      ownership: { $0.1 },
      validate: { try self.state.validate(access) })
  }
}

@Suite struct NativeBitwardenFillCredentialTests {
  private let origin = PasswordFillOrigin("https://example.test")!

  private func candidate(
    id: UUID, organization: Bool = false, login: Bool = true, deleted: Bool = false,
    archived: Bool = false, partial: Bool = false, viewPassword: Bool = true,
    reprompt: Bool = false, username: String? = "synthetic-user",
    password: String? = "synthetic-password", uris: [NativeBitwardenFillURI]? = nil
  ) -> NativeBitwardenFillCandidate {
    NativeBitwardenFillCandidate(
      id: id, organization: organization, login: login, deleted: deleted, archived: archived,
      partial: partial, viewPassword: viewPassword, reprompt: reprompt, username: username,
      password: password, uris: uris ?? [.init(value: "https://example.test", mode: .host)])
  }

  @Test func onlyEligiblePersonalLoginCanReturnTransientCredential() throws {
    let id = UUID()
    let valid = candidate(id: id)
    let credential = try NativeBitwardenFillPolicy.credential(from: valid, id: id, origin: origin)
    #expect(credential.username == "synthetic-user")
    #expect(credential.password == "synthetic-password")
    #expect(!String(reflecting: credential).contains("synthetic-password"))
    #expect(throws: NativeBitwardenFillError.organizationUnsupported) {
      try NativeBitwardenFillPolicy.credential(
        from: candidate(id: id, organization: true), id: id, origin: origin)
    }
    for item in [
      candidate(id: UUID()), candidate(id: id, login: false), candidate(id: id, deleted: true),
      candidate(id: id, archived: true), candidate(id: id, partial: true),
      candidate(id: id, viewPassword: false), candidate(id: id, username: nil),
      candidate(id: id, password: nil), candidate(id: id, username: ""),
      candidate(id: id, password: ""),
    ] {
      #expect(throws: NativeBitwardenFillError.ineligibleCipher) {
        try NativeBitwardenFillPolicy.credential(from: item, id: id, origin: origin)
      }
    }
    #expect(throws: NativeBitwardenFillError.repromptRequired) {
      try NativeBitwardenFillPolicy.credential(
        from: candidate(id: id, reprompt: true), id: id, origin: origin)
    }
  }

  @Test func organizationOwnershipRequiresMatchingEncryptedAndDecryptedIdentity() throws {
    let id = UUID()
    let organizationID = UUID()
    var item = candidate(id: id, organization: true)
    item.organizationID = organizationID
    #expect(throws: NativeBitwardenFillError.organizationUnsupported) {
      try NativeBitwardenFillPolicy.credential(from: item, id: id, origin: origin)
    }
    #expect(
      try NativeBitwardenFillPolicy.credential(
        from: item, id: id, origin: origin, ownership: .organization(organizationID)
      ).username
        == "synthetic-user")
    #expect(throws: NativeBitwardenFillError.ineligibleCipher) {
      try NativeBitwardenFillPolicy.credential(
        from: item, id: id, origin: origin, ownership: .organization(UUID()))
    }
    #expect(throws: NativeBitwardenFillError.ineligibleCipher) {
      try NativeBitwardenFillPolicy.credential(
        from: candidate(id: id), id: id, origin: origin, ownership: .organization(organizationID))
    }
    #expect(throws: NativeBitwardenFillError.ineligibleCipher) {
      try NativeBitwardenFillPolicy.credential(
        from: item, id: UUID(), origin: origin, ownership: .organization(organizationID))
    }
  }

  @Test func membershipReplacementAndFailedSyncRevokeCapabilities() throws {
    let id = UUID()
    let org = UUID()
    let replacement = UUID()
    var state = NativeBitwardenFillAccessState<NativeBitwardenFillCandidate>(sessionID: UUID())
    let first = try state.beginSync()
    try state.publish(
      ticket: first, snapshot: .empty, items: [id: candidate(id: id)],
      organizationIDs: [org])
    state.finishSync(first)
    let old = try state.snapshot().access
    #expect(try state.ownership(access: old, organizationID: org) == .organization(org))
    #expect(throws: NativeBitwardenFillError.organizationUnsupported) {
      try state.ownership(access: old, organizationID: replacement)
    }
    let next = try state.beginSync()
    #expect(throws: NativeBitwardenFillError.staleAccess) {
      try state.ownership(access: old, organizationID: org)
    }
    try state.publish(
      ticket: next, snapshot: .empty, items: [id: candidate(id: id)],
      organizationIDs: [replacement])
    state.finishSync(next)
    let current = try state.snapshot().access
    #expect(throws: NativeBitwardenFillError.organizationUnsupported) {
      try state.ownership(access: current, organizationID: org)
    }
    #expect(try state.ownership(access: current, organizationID: nil) == .personal)
    let failed = try state.beginSync()
    state.finishSync(failed)
    #expect(throws: NativeBitwardenFillError.staleAccess) { try state.validate(current) }
    let empty = try state.beginSync()
    try state.publish(ticket: empty, snapshot: .empty, items: [id: candidate(id: id)])
    state.finishSync(empty)
    let emptyAccess = try state.snapshot().access
    #expect(throws: NativeBitwardenFillError.organizationUnsupported) {
      try state.ownership(access: emptyAccess, organizationID: replacement)
    }
    #expect(try state.ownership(access: emptyAccess, organizationID: nil) == .personal)
  }

  @Test func uriModesFailClosedWithoutFullURLOrMatchEngine() throws {
    let id = UUID()
    for mode in [NativeBitwardenFillURIMode.never, .host] {
      let uri = NativeBitwardenFillURI(value: "https://other.example.test", mode: mode)
      #expect(throws: NativeBitwardenFillError.noMatchingURI) {
        try NativeBitwardenFillPolicy.credential(
          from: candidate(id: id, uris: [uri]), id: id, origin: origin)
      }
    }
    for value in [
      "http://example.test", "https://example.test:8443", "https://sub.example.test/path",
      "https://example.test.evil/path", "https://user@example.test/path", "https://example.test:",
    ] {
      #expect(throws: NativeBitwardenFillError.noMatchingURI) {
        try NativeBitwardenFillPolicy.credential(
          from: candidate(id: id, uris: [.init(value: value, mode: .host)]), id: id, origin: origin)
      }
    }
    for value in [
      "https://example.test/", "https://EXAMPLE.test:443/path?x=1#fragment",
    ] {
      let matched = candidate(id: id, uris: [.init(value: value, mode: .host)])
      #expect(
        try NativeBitwardenFillPolicy.credential(from: matched, id: id, origin: origin)
          .username == "synthetic-user")
    }
    let nondefault = PasswordFillOrigin("https://example.test:8443")!
    let portMatch = candidate(
      id: id, uris: [.init(value: "https://example.test:8443/a", mode: .host)])
    #expect(
      try NativeBitwardenFillPolicy.credential(from: portMatch, id: id, origin: nondefault)
        .username == "synthetic-user")
    #expect(throws: NativeBitwardenFillError.unsupportedMatch) {
      try NativeBitwardenFillPolicy.credential(
        from: candidate(id: id, uris: [.init(value: origin.value, mode: .unsupported)]),
        id: id, origin: origin)
    }
    let mixed = candidate(
      id: id,
      uris: [
        .init(value: origin.value, mode: .never), .init(value: origin.value, mode: .host),
      ])
    #expect(
      try NativeBitwardenFillPolicy.credential(from: mixed, id: id, origin: origin).username
        == "synthetic-user")
  }

  #if canImport(ArcusisBitwardenSDK)
    @Test func mapsActualSDKViewEligibilityAndMatchModes() throws {
      let id = UUID()
      func makeView(
        _ mode: UriMatchType?, reprompt: CipherRepromptType = .none, organizationID: UUID? = nil,
        viewPassword: Bool = true, partial: Bool = false
      ) -> CipherView {
        CipherView(
          id: id.uuidString, organizationId: organizationID?.uuidString, folderId: nil,
          collectionIds: [], key: nil,
          name: "synthetic", notes: nil, type: .login,
          login: LoginView(
            username: "synthetic-user", password: "synthetic-password", passwordRevisionDate: nil,
            uris: [LoginUriView(uri: "https://example.test/path", match: mode, uriChecksum: nil)],
            totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil),
          identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
          driversLicense: nil, passport: nil, favorite: false, reprompt: reprompt,
          organizationUseTotp: false, edit: true, permissions: nil, viewPassword: viewPassword,
          localData: nil, attachments: nil, attachmentDecryptionFailures: nil, fields: nil,
          passwordHistory: nil, creationDate: Date(timeIntervalSince1970: 0), deletedDate: nil,
          revisionDate: Date(timeIntervalSince1970: 0), archivedDate: nil, partial: partial)
      }
      let mapped = NativeBitwardenSDKBackend.fillCandidate(makeView(.host))
      let credential = try NativeBitwardenFillPolicy.credential(
        from: mapped, id: id, origin: origin)
      #expect(credential.username == "synthetic-user")
      #expect(credential.password == "synthetic-password")
      let unsupported: [UriMatchType?] = [.domain, .startsWith, .exact, .regularExpression, nil]
      for mode in unsupported {
        let mapped = NativeBitwardenSDKBackend.fillCandidate(makeView(mode))
        #expect(throws: NativeBitwardenFillError.unsupportedMatch) {
          try NativeBitwardenFillPolicy.credential(from: mapped, id: id, origin: origin)
        }
      }
      let organizationID = UUID()
      let shared = NativeBitwardenSDKBackend.fillCandidate(
        makeView(.host, organizationID: organizationID))
      #expect(shared.organizationID == organizationID)
      #expect(
        try NativeBitwardenFillPolicy.credential(
          from: shared, id: id, origin: origin, ownership: .organization(organizationID)
        ).username
          == "synthetic-user")
      #expect(throws: NativeBitwardenFillError.ineligibleCipher) {
        try NativeBitwardenFillPolicy.credential(
          from: shared, id: id, origin: origin, ownership: .organization(UUID()))
      }
      let never = NativeBitwardenSDKBackend.fillCandidate(makeView(.never))
      #expect(throws: NativeBitwardenFillError.noMatchingURI) {
        try NativeBitwardenFillPolicy.credential(from: never, id: id, origin: origin)
      }
      let reprompt = NativeBitwardenSDKBackend.fillCandidate(makeView(.host, reprompt: .password))
      #expect(throws: NativeBitwardenFillError.repromptRequired) {
        try NativeBitwardenFillPolicy.credential(from: reprompt, id: id, origin: origin)
      }
      for view in [
        makeView(.host, organizationID: organizationID, viewPassword: false),
        makeView(.host, organizationID: organizationID, partial: true),
      ] {
        let restricted = NativeBitwardenSDKBackend.fillCandidate(view)
        #expect(throws: NativeBitwardenFillError.ineligibleCipher) {
          try NativeBitwardenFillPolicy.credential(
            from: restricted, id: id, origin: origin, ownership: .organization(organizationID))
        }
      }
    }
  #endif

  @Test func syncRevokesPriorAndRejectsStaleOrForeignSnapshots() throws {
    let session = UUID()
    let id = UUID()
    let item = candidate(id: id)
    var state = NativeBitwardenFillAccessState<NativeBitwardenFillCandidate>(sessionID: session)
    let first = try state.beginSync()
    try state.publish(ticket: first, snapshot: .empty, items: [id: item])
    state.finishSync(first)
    let old = try state.snapshot().access
    #expect(throws: NativeBitwardenFillError.cipherUnavailable) {
      try state.item(access: old, id: UUID())
    }
    var other = NativeBitwardenFillAccessState<NativeBitwardenFillCandidate>(sessionID: UUID())
    let foreignRevision = try other.beginSync()
    try other.publish(ticket: foreignRevision, snapshot: .empty, items: [id: item])
    other.finishSync(foreignRevision)
    #expect(throws: NativeBitwardenFillError.staleAccess) { try other.item(access: old, id: id) }
    let failed = try state.beginSync()
    #expect(throws: NativeBitwardenFillError.staleAccess) { try state.snapshot() }
    #expect(throws: NativeBitwardenFillError.staleAccess) { try state.item(access: old, id: id) }
    state.finishSync(failed)
    let latest = try state.beginSync()
    #expect(throws: NativeBitwardenFillError.staleAccess) {
      try state.publish(ticket: failed, snapshot: .empty, items: [id: item])
    }
    try state.publish(ticket: latest, snapshot: .empty, items: [id: item])
    let current = try state.snapshot().access
    #expect(throws: NativeBitwardenFillError.staleAccess) {
      try state.publish(ticket: latest, snapshot: .empty, items: [:])
    }
    #expect(current != old)
    #expect(try state.item(access: current, id: id).id == id)
    #expect(throws: NativeBitwardenFillError.staleAccess) { try state.validate(old) }
  }

  @Test func inFlightDecryptCannotReturnAfterLockDiscardOrResync() async throws {
    for action in 0..<3 {
      let decryptor = DeferredFillDecryptor()
      let backend = MemoryFillBackend(sessionID: UUID(), decryptor: decryptor)
      let id = UUID()
      let item = candidate(id: id)
      let first = try await backend.beginSync()
      try await backend.finishSync(first, id: id, item: item)
      let access = try await backend.access()
      let task = Task { try await backend.lookup(access: access, id: id, origin: origin) }
      await decryptor.waitUntilStarted()
      if action == 2 {
        let next = try await backend.beginSync()
        try await backend.finishSync(next, id: id, item: item)
      } else {
        await backend.lockOrDiscard()
      }
      await decryptor.resolve(item)
      await #expect(throws: NativeBitwardenFillError.staleAccess) { try await task.value }
      if action == 2 { #expect(try await backend.access() != access) }
    }
  }

  @Test func overlappingSyncRevokesAndLateCompletionCannotPublishOrClearSuccessor() async throws {
    let decryptor = DeferredFillDecryptor()
    let backend = MemoryFillBackend(sessionID: UUID(), decryptor: decryptor)
    let id = UUID()
    let item = candidate(id: id)
    let initial = try await backend.beginSync()
    try await backend.finishSync(initial, id: id, item: item)
    let accepted = try await backend.access()
    let old = try await backend.beginSync()
    let oldTask = Task {
      let value = await decryptor.decrypt(item)
      try await backend.finishSync(old, id: id, item: value)
    }
    await decryptor.waitUntilStarted()
    await #expect(throws: NativeBitwardenFillError.syncInProgress) { try await backend.beginSync() }
    await #expect(throws: NativeBitwardenFillError.staleAccess) { try await backend.access() }
    await decryptor.resolve(item)
    await #expect(throws: NativeBitwardenFillError.staleAccess) { try await oldTask.value }
    let next = try await backend.beginSync()
    await #expect(throws: NativeBitwardenFillError.staleAccess) {
      try await backend.finishSync(old, id: id, item: item)
    }
    await #expect(throws: NativeBitwardenFillError.syncInProgress) { try await backend.beginSync() }
    await #expect(throws: NativeBitwardenFillError.staleAccess) {
      try await backend.finishSync(next, id: id, item: item)
    }
    let final = try await backend.beginSync()
    try await backend.finishSync(final, id: id, item: item)
    #expect(try await backend.access() != accepted)
  }

  @Test func onDemandDecryptPublishesCredentialOnlyForCurrentAccess() async throws {
    let decryptor = DeferredFillDecryptor()
    let backend = MemoryFillBackend(sessionID: UUID(), decryptor: decryptor)
    let id = UUID()
    let item = candidate(id: id)
    let revision = try await backend.beginSync()
    try await backend.finishSync(revision, id: id, item: item)
    let access = try await backend.access()
    let task = Task { try await backend.lookup(access: access, id: id, origin: origin) }
    await decryptor.waitUntilStarted()
    await decryptor.resolve(item)
    let credential = try await task.value
    #expect(credential.username == "synthetic-user")
    #expect(credential.password == "synthetic-password")
  }

  @Test func organizationDecryptCannotReturnAfterMembershipRevocation() async throws {
    let decryptor = DeferredFillDecryptor()
    let backend = MemoryFillBackend(sessionID: UUID(), decryptor: decryptor)
    let id = UUID()
    let org = UUID()
    var item = candidate(id: id, organization: true)
    item.organizationID = org
    let first = try await backend.beginSync()
    try await backend.finishSync(first, id: id, item: item, organizationIDs: [org])
    let access = try await backend.access()
    let task = Task { try await backend.lookup(access: access, id: id, origin: origin) }
    await decryptor.waitUntilStarted()
    let next = try await backend.beginSync()
    try await backend.finishSync(next, id: id, item: item)
    await decryptor.resolve(item)
    await #expect(throws: NativeBitwardenFillError.staleAccess) { try await task.value }
    let current = try await backend.access()
    await #expect(throws: NativeBitwardenFillError.organizationUnsupported) {
      try await backend.lookup(access: current, id: id, origin: origin)
    }
  }

  @Test func cancellationAfterDecryptionStartedDoesNotReturnCredential() async throws {
    let decryptor = DeferredFillDecryptor()
    let backend = MemoryFillBackend(sessionID: UUID(), decryptor: decryptor)
    let id = UUID()
    let item = candidate(id: id)
    let revision = try await backend.beginSync()
    try await backend.finishSync(revision, id: id, item: item)
    let access = try await backend.access()
    let task = Task { try await backend.lookup(access: access, id: id, origin: origin) }
    await decryptor.waitUntilStarted()
    task.cancel()
    await decryptor.resolve(item)
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
