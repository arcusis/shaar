import Foundation
import Testing

@testable import ArcusisBrowser

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif

@Suite
struct NativeBitwardenVaultSnapshotTests {
  #if canImport(ArcusisBitwardenSDK)
    @Test func convertsTypedSDKCipherViewToRedactedPersonalLoginMetadata() throws {
      let cipherID = UUID()
      let view = CipherView(
        id: cipherID.uuidString, organizationId: nil, folderId: nil, collectionIds: [], key: nil,
        name: "Work", notes: nil, type: .login,
        login: LoginView(
          username: "alice", password: "must-not-escape", passwordRevisionDate: nil,
          uris: [LoginUriView(uri: "https://example.test", match: nil, uriChecksum: nil)],
          totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil),
        identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
        driversLicense: nil, passport: nil, favorite: false, reprompt: .none,
        organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true,
        localData: nil, attachments: nil, attachmentDecryptionFailures: nil, fields: nil,
        passwordHistory: nil, creationDate: Date(timeIntervalSince1970: 0), deletedDate: nil,
        revisionDate: Date(timeIntervalSince1970: 0), archivedDate: nil, partial: false)
      let metadata = try NativeBitwardenVaultSnapshot.metadata(from: view)
      let snapshot = try NativeBitwardenVaultSnapshot.make(from: [metadata])
      #expect(snapshot.logins.map(\.id) == [cipherID])
      #expect(snapshot.logins.first?.username == "alice")
      #expect(snapshot.logins.first?.uris.map(\.uri) == ["https://example.test"])
      #expect(snapshot.logins.first?.name == "Work")
    }
  #endif

  #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
    @Test func candidateExposesTypedPairedSnapshot() {
      let org = UUID().uuidString.lowercased()
      let paired = EncryptedSyncSnapshot(
        generation: 7, ciphers: [], organizationKeys: [org: "synthetic"])
      let request = InitOrgCryptoRequest(organizationKeys: paired.organizationKeys)
      #expect(paired.generation == 7)
      #expect(request.organizationKeys == [org: "synthetic"])
    }
  #endif

  @Test func emptyVaultIsValid() throws {
    try NativeBitwardenVaultSnapshot.requireCompletedSync(true)
    let snapshot = try NativeBitwardenVaultSnapshot.make(from: [])
    #expect(snapshot == .empty)
    #expect(snapshot.logins.isEmpty)
    #expect(snapshot.personalNonLoginCipherCount == 0)
    #expect(snapshot.organizationCipherCount == 0)
    #expect(snapshot.missingCipherIDCount == 0)
  }

  @Test func falseSyncAndDuplicateCipherIDsAreExplicitErrors() {
    #expect(throws: NativeBitwardenVaultSnapshotError.syncNotPerformed) {
      try NativeBitwardenVaultSnapshot.requireCompletedSync(false)
    }
    let duplicateID = UUID()
    #expect(throws: NativeBitwardenVaultSnapshotError.duplicateCipherID) {
      try NativeBitwardenVaultSnapshot.make(from: [
        .init(
          id: duplicateID, name: "First", username: nil, uris: [], isLogin: true,
          isOrganization: false),
        .init(
          id: duplicateID, name: "Second", username: nil, uris: [], isLogin: true,
          isOrganization: false),
      ])
    }
  }

  @Test func includesOnlyPersonalLoginsAndReportsPartialCoverage() throws {
    let loginID = UUID()
    let snapshot = try NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: loginID, name: "Personal", username: nil, uris: ["https://example.test"],
        isLogin: true, isOrganization: false),
      .init(
        id: UUID(), name: "Note", username: nil, uris: [], isLogin: false, isOrganization: false),
      .init(
        id: UUID(), name: "Org login", username: "org", uris: [], isLogin: true,
        isOrganization: true),
      .init(
        id: nil, name: "Missing", username: nil, uris: [], isLogin: true, isOrganization: false),
    ])
    #expect(snapshot.logins.count == 1)
    #expect(snapshot.logins[0].id == loginID)
    #expect(snapshot.logins[0].name == "Personal")
    #expect(snapshot.logins[0].username == nil)
    #expect(snapshot.logins[0].uris.map(\.uri) == ["https://example.test"])
    #expect(snapshot.fetchedCipherCount == 4)
    #expect(snapshot.totalCipherCount == 4)
    #expect(snapshot.personalNonLoginCipherCount == 1)
    #expect(snapshot.organizationCipherCount == 1)
    #expect(snapshot.missingCipherIDCount == 1)
  }

  @Test func organizationMetadataRequiresMembershipAndPreservesPersonalLogins() throws {
    let org = UUID()
    let personal = UUID()
    let shared = UUID()
    let ciphers: [NativeBitwardenVaultSnapshot.CipherMetadata] = [
      .init(
        id: personal, name: "Personal", username: nil, uris: [], isLogin: true,
        isOrganization: false),
      .init(
        id: shared, name: "Shared", username: nil, uris: [], isLogin: true,
        isOrganization: true, organizationID: org),
    ]
    #expect(try NativeBitwardenVaultSnapshot.make(from: ciphers).logins.map(\.id) == [personal])
    let accepted = try NativeBitwardenVaultSnapshot.make(from: ciphers, organizationIDs: [org])
    #expect(accepted.logins.map(\.id) == [personal, shared])
    #expect(accepted.logins.last?.organizationID == org)
    #expect(
      try NativeBitwardenVaultSnapshot.make(from: ciphers, organizationIDs: [UUID()])
        .logins.map(\.id) == [personal])
  }

  @Test func malformedOrForeignOwnershipCannotPublish() throws {
    let id = UUID().uuidString
    let org = UUID()
    let other = UUID()
    func validate(
      _ encryptedID: String?, _ encryptedOrg: String?, _ viewID: String?,
      _ viewOrg: String?, _ membership: Set<UUID>
    ) throws {
      try NativeBitwardenVaultSnapshot.validateOwnership(
        encryptedID: encryptedID, encryptedOrganizationID: encryptedOrg,
        viewID: viewID, viewOrganizationID: viewOrg, organizationIDs: membership)
    }
    try validate(id, org.uuidString, id, org.uuidString, [org])
    try validate(id, nil, id, nil, [])
    #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
      #expect(throws: NativeBitwardenVaultSnapshotError.invalidOwnership) {
        try validate(nil, org.uuidString, nil, org.uuidString, [org])
      }
      #expect(throws: NativeBitwardenVaultSnapshotError.invalidOwnership) {
        try validate(nil, nil, nil, nil, [])
      }
    #else
      try validate(nil, nil, nil, nil, [])
    #endif
    for (encryptedID, encryptedOrg, viewID, viewOrg, membership) in [
      (id, org.uuidString, id, other.uuidString, Set([org])),
      (id, org.uuidString, id, nil, Set([org])),
      (id, nil, id, org.uuidString, Set([org])),
      (id, org.uuidString, UUID().uuidString, org.uuidString, Set([org])),
      (id, org.uuidString, id, org.uuidString, Set<UUID>()),
      (id, "invalid", id, "invalid", Set<UUID>()),
      ("invalid", nil, "invalid", nil, Set<UUID>()),
    ] {
      var state = NativeBitwardenFillAccessState<Int>(sessionID: UUID())
      let ticket = try state.beginSync()
      #expect(throws: NativeBitwardenVaultSnapshotError.invalidOwnership) {
        try validate(encryptedID, encryptedOrg, viewID, viewOrg, membership)
        try state.publish(ticket: ticket, snapshot: .empty, items: [:])
      }
      state.finishSync(ticket)
      #expect(throws: NativeBitwardenFillError.staleAccess) { try state.snapshot() }
    }
  }

  #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
    @Test func missingCipherIDRevokesPreviouslyAcceptedAccess() throws {
      let organizationID = UUID()
      var state = NativeBitwardenFillAccessState<Int>(sessionID: UUID())
      let first = try state.beginSync()
      try state.publish(ticket: first, snapshot: .empty, items: [:])
      state.finishSync(first)
      let previous = try state.snapshot().access
      let next = try state.beginSync()
      #expect(throws: NativeBitwardenVaultSnapshotError.invalidOwnership) {
        try NativeBitwardenVaultSnapshot.validateOwnership(
          encryptedID: nil, encryptedOrganizationID: organizationID.uuidString,
          viewID: nil, viewOrganizationID: organizationID.uuidString,
          organizationIDs: [organizationID])
        try state.publish(ticket: next, snapshot: .empty, items: [:])
      }
      state.finishSync(next)
      #expect(throws: NativeBitwardenFillError.staleAccess) { try state.validate(previous) }
      #expect(throws: NativeBitwardenFillError.staleAccess) { try state.snapshot() }
    }
  #endif

  @Test func rejectsOversizedVaultAndMetadata() {
    let tooMany = Array(
      repeating: NativeBitwardenVaultSnapshot.CipherMetadata(
        id: UUID(), name: "x", username: nil, uris: [], isLogin: true, isOrganization: false),
      count: NativeBitwardenVaultSnapshot.maximumCipherCount + 1)
    #expect(throws: NativeBitwardenVaultSnapshotError.tooManyCiphers) {
      try NativeBitwardenVaultSnapshot.make(from: tooMany)
    }
    #expect(throws: NativeBitwardenVaultSnapshotError.metadataTooLarge) {
      try NativeBitwardenVaultSnapshot.make(from: [
        .init(
          id: UUID(), name: String(repeating: "x", count: 1_025), username: nil, uris: [],
          isLogin: true, isOrganization: false)
      ])
    }
    #expect(throws: NativeBitwardenVaultSnapshotError.metadataTooLarge) {
      try NativeBitwardenVaultSnapshot.make(from: [
        .init(
          id: UUID(), name: "x", username: nil,
          uris: [String(repeating: "x", count: 2_049)], isLogin: true, isOrganization: false)
      ])
    }
  }
}
