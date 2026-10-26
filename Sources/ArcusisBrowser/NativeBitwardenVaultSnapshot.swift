import Foundation

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif

struct NativeBitwardenLoginURI: Equatable, Sendable {
  let uri: String
}

struct NativeBitwardenLoginMetadata: Equatable, Sendable, Identifiable {
  let id: UUID
  let name: String
  let username: String?
  let uris: [NativeBitwardenLoginURI]
}

struct NativeBitwardenVaultSnapshot: Equatable, Sendable {
  struct CipherMetadata: Equatable, Sendable {
    let id: UUID?
    let name: String
    let username: String?
    let uris: [String]
    let isLogin: Bool
    let isOrganization: Bool
  }

  let logins: [NativeBitwardenLoginMetadata]
  let fetchedCipherCount: Int
  let personalNonLoginCipherCount: Int
  let organizationCipherCount: Int
  let missingCipherIDCount: Int

  var totalCipherCount: Int { fetchedCipherCount }

  static let empty = NativeBitwardenVaultSnapshot(
    logins: [], fetchedCipherCount: 0, personalNonLoginCipherCount: 0, organizationCipherCount: 0,
    missingCipherIDCount: 0)

  static let maximumCipherCount = 5_000
  static let maximumSnapshotMetadataBytes = 16 * 1_024 * 1_024
  static let maximumNameBytes = 1_024
  static let maximumUsernameBytes = 1_024
  static let maximumURICount = 50
  static let maximumURIBytes = 2_048

  static func requireCompletedSync(_ didSynchronize: Bool) throws {
    guard didSynchronize else { throw NativeBitwardenVaultSnapshotError.syncNotPerformed }
  }

  static func make(from ciphers: [CipherMetadata]) throws -> Self {
    guard ciphers.count <= maximumCipherCount else {
      throw NativeBitwardenVaultSnapshotError.tooManyCiphers
    }
    var logins: [NativeBitwardenLoginMetadata] = []
    var personalNonLoginCipherCount = 0
    var organizationCipherCount = 0
    var missingCipherIDCount = 0
    var metadataBytes = 0
    var seenIDs: Set<UUID> = []
    for cipher in ciphers {
      if cipher.isOrganization { organizationCipherCount += 1 }
      guard let id = cipher.id else {
        missingCipherIDCount += 1
        continue
      }
      guard seenIDs.insert(id).inserted else {
        throw NativeBitwardenVaultSnapshotError.duplicateCipherID
      }
      guard !cipher.isOrganization else { continue }
      guard cipher.isLogin else {
        personalNonLoginCipherCount += 1
        continue
      }
      guard cipher.name.utf8.count <= maximumNameBytes,
        cipher.username.map({ $0.utf8.count <= maximumUsernameBytes }) ?? true,
        cipher.uris.count <= maximumURICount,
        cipher.uris.allSatisfy({ $0.utf8.count <= maximumURIBytes })
      else { throw NativeBitwardenVaultSnapshotError.metadataTooLarge }
      metadataBytes +=
        cipher.name.utf8.count + (cipher.username?.utf8.count ?? 0)
        + cipher.uris.reduce(0) { $0 + $1.utf8.count } + id.uuidString.utf8.count
      guard metadataBytes <= maximumSnapshotMetadataBytes else {
        throw NativeBitwardenVaultSnapshotError.metadataTooLarge
      }
      logins.append(
        NativeBitwardenLoginMetadata(
          id: id, name: cipher.name, username: cipher.username,
          uris: cipher.uris.map(NativeBitwardenLoginURI.init(uri:))))
    }
    return Self(
      logins: logins, fetchedCipherCount: ciphers.count,
      personalNonLoginCipherCount: personalNonLoginCipherCount,
      organizationCipherCount: organizationCipherCount,
      missingCipherIDCount: missingCipherIDCount)
  }

  #if canImport(ArcusisBitwardenSDK)
    static func metadata(from view: CipherView) throws -> CipherMetadata {
      let isLogin = view.type == .login
      let uris = isLogin ? (view.login?.uris ?? []).compactMap(\.uri) : []
      guard
        !isLogin
          || (view.name.utf8.count <= maximumNameBytes
            && (view.login?.username.map({ $0.utf8.count <= maximumUsernameBytes }) ?? true)
            && (view.login?.uris?.count ?? 0) <= maximumURICount
            && uris.allSatisfy({ $0.utf8.count <= maximumURIBytes }))
      else { throw NativeBitwardenVaultSnapshotError.metadataTooLarge }
      return CipherMetadata(
        id: view.id.flatMap(UUID.init(uuidString:)), name: isLogin ? view.name : "",
        username: isLogin ? view.login?.username : nil, uris: uris,
        isLogin: isLogin, isOrganization: view.organizationId != nil)
    }
  #endif
}

enum NativeBitwardenVaultSnapshotError: Error, Equatable, Sendable {
  case syncNotPerformed
  case tooManyCiphers
  case metadataTooLarge
  case duplicateCipherID
}
