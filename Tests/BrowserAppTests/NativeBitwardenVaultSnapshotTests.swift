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
