import Foundation
import LocalAuthentication
import Security

public struct PasswordCredential: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?

  public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }

  public var description: String { "PasswordCredential(<redacted>)" }

  public var debugDescription: String { "PasswordCredential(<redacted>)" }
}

struct PasswordCredentialProbeNamespace: Sendable {
  let id: UUID

  init() {
    id = UUID()
  }
}

public enum PasswordCredentialStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidAuthority
  case invalidCredential
  case recordTooLarge
  case corruptRecord
  case unsupportedRecordVersion(Int)
  case bindingMismatch
  case recoveryConflict
  case storage(operation: Operation, status: Int32)

  public enum Operation: String, Sendable {
    case read
    case write
    case delete
  }

  public var description: String {
    switch self {
    case .invalidAuthority:
      return "Password credential authority is invalid."
    case .invalidCredential:
      return "Password credential is invalid."
    case .recordTooLarge:
      return "Password credential record exceeds the size limit."
    case .corruptRecord:
      return "Password credential record is corrupt."
    case .unsupportedRecordVersion(let version):
      return "Password credential record version \(version) is unsupported."
    case .bindingMismatch:
      return "Password credential record does not match its binding."
    case .recoveryConflict:
      return "Password recovery record changed or requires explicit recovery handling."
    case .storage(let operation, let status):
      return "Password credential storage \(operation.rawValue) failed (status \(status))."
    }
  }
}

/// Persists access and optional refresh tokens under a browser Profile and password-vault binding.
/// Callers own authentication, refresh, session publication, and logout policy.
public final class PasswordCredentialStore: Sendable {
  private static let recordVersion = 1
  private static let maximumTokenBytes = 8_192
  private static let maximumRecordBytes = 16_384
  private static let applicationService = "com.arcusis.browser.password-credentials"
  private static let probeServicePrefix = "\(applicationService).probe"

  private let service: String
  private let storage: any PasswordCredentialItemStorage
  private let usesSessionLocks: Bool
  private let sessionLockDirectory: URL?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init() {
    self.service = Self.applicationService
    self.storage = KeychainPasswordCredentialStorage()
    self.usesSessionLocks = true
    self.sessionLockDirectory = nil
  }

  init(probeNamespace: PasswordCredentialProbeNamespace) {
    self.service = "\(Self.probeServicePrefix).\(probeNamespace.id.uuidString.lowercased())"
    self.storage = KeychainPasswordCredentialStorage()
    self.usesSessionLocks = true
    self.sessionLockDirectory = nil
  }

  init(
    service: String, storage: any PasswordCredentialItemStorage, sessionLockDirectory: URL? = nil,
    usesSessionLocks: Bool = false
  ) {
    self.service = service
    self.storage = storage
    self.usesSessionLocks = usesSessionLocks
    self.sessionLockDirectory = sessionLockDirectory
  }

  public func acquireSessionLock(for binding: PasswordAuthenticationBinding) throws
    -> PasswordCredentialSessionLock
  {
    if let sessionLockDirectory {
      return try PasswordCredentialSessionLock.acquire(
        service: service, binding: binding, applicationSupport: sessionLockDirectory)
    }
    return try PasswordCredentialSessionLock.acquire(service: service, binding: binding)
  }

  private func operationLock(
    for binding: PasswordAuthenticationBinding, lease: PasswordCredentialSessionLock?
  ) throws -> PasswordCredentialSessionLock? {
    if let lease {
      guard try lease.matches(service: service, binding: binding) else {
        throw PasswordCredentialStoreError.bindingMismatch
      }
      return lease
    }
    return try usesSessionLocks ? acquireSessionLock(for: binding) : nil
  }

  public func read(
    for binding: PasswordAuthenticationBinding, lease: PasswordCredentialSessionLock? = nil
  ) throws -> PasswordCredential? {
    let held = try operationLock(for: binding, lease: lease)
    defer { withExtendedLifetime(held) {} }
    let authority = try Self.canonicalAuthority(binding.authority)
    let account = Self.accountName(for: binding, authority: authority)
    let data: Data
    do {
      guard let stored = try storage.read(service: service, account: account) else { return nil }
      data = stored
    } catch let error as PasswordCredentialStoreError {
      throw error
    } catch {
      throw Self.storageError(.read, error)
    }

    guard data.count <= Self.maximumRecordBytes else {
      throw PasswordCredentialStoreError.recordTooLarge
    }
    let record: CredentialRecord
    do {
      record = try decoder.decode(CredentialRecord.self, from: data)
    } catch {
      throw PasswordCredentialStoreError.corruptRecord
    }
    guard record.version == Self.recordVersion else {
      throw PasswordCredentialStoreError.unsupportedRecordVersion(record.version)
    }
    guard record.profileID == binding.profileID, record.vaultID == binding.vaultID,
      record.accountID == binding.accountID, record.authority == authority
    else {
      throw PasswordCredentialStoreError.bindingMismatch
    }
    guard Self.validToken(record.accessToken) else {
      throw PasswordCredentialStoreError.corruptRecord
    }
    if let refreshToken = record.refreshToken, !Self.validToken(refreshToken) {
      throw PasswordCredentialStoreError.corruptRecord
    }
    return PasswordCredential(
      accessToken: record.accessToken, refreshToken: record.refreshToken,
      expiresAt: record.expiresAt)
  }

  public func write(
    _ credential: PasswordCredential, for binding: PasswordAuthenticationBinding,
    lease: PasswordCredentialSessionLock? = nil
  ) throws {
    let held = try operationLock(for: binding, lease: lease)
    defer { withExtendedLifetime(held) {} }
    let authority = try Self.canonicalAuthority(binding.authority)
    guard Self.validToken(credential.accessToken) else {
      throw PasswordCredentialStoreError.invalidCredential
    }
    if let refreshToken = credential.refreshToken, !Self.validToken(refreshToken) {
      throw PasswordCredentialStoreError.invalidCredential
    }
    do {
      if let existing = try storage.read(
        service: service, account: Self.accountName(for: binding, authority: authority))
      {
        guard existing.count <= 128 * 1024,
          let json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
          let version = json["version"] as? Int, version == Self.recordVersion
        else { throw PasswordCredentialStoreError.recoveryConflict }
      }
    } catch let error as PasswordCredentialStoreError {
      throw error
    } catch {
      throw Self.storageError(.write, error)
    }
    let record = CredentialRecord(
      version: Self.recordVersion,
      profileID: binding.profileID,
      vaultID: binding.vaultID,
      accountID: binding.accountID,
      authority: authority,
      accessToken: credential.accessToken,
      refreshToken: credential.refreshToken,
      expiresAt: credential.expiresAt
    )
    let data: Data
    do {
      data = try encoder.encode(record)
    } catch {
      throw PasswordCredentialStoreError.corruptRecord
    }
    guard data.count <= Self.maximumRecordBytes else {
      throw PasswordCredentialStoreError.recordTooLarge
    }

    do {
      try storage.write(
        data, service: service, account: Self.accountName(for: binding, authority: authority))
    } catch let error as PasswordCredentialStoreError {
      throw error
    } catch {
      throw Self.storageError(.write, error)
    }
  }

  public enum RecoveryLookup: Equatable, Sendable {
    case missing
    case legacy
    case record(PasswordSessionRecoveryRecord)
  }

  /// Recovery writes require a held lease across read, network rotation, and publication.
  public func readRecovery(
    for binding: PasswordAuthenticationBinding, identityURL: URL, apiURL: URL,
    serviceID: String, deviceID: UUID, clientID: String, sdkRevision: String,
    lease: PasswordCredentialSessionLock
  ) throws -> RecoveryLookup {
    let held = try operationLock(for: binding, lease: lease)
    defer { withExtendedLifetime(held) {} }
    let authority = try Self.canonicalAuthority(binding.authority)
    let data: Data
    do {
      guard
        let value = try storage.read(
          service: service, account: Self.accountName(for: binding, authority: authority))
      else { return .missing }
      data = value
    } catch let error as PasswordCredentialStoreError {
      throw error
    } catch {
      throw Self.storageError(.read, error)
    }
    guard data.count <= 128 * 1024 else { throw PasswordCredentialStoreError.recordTooLarge }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = json["version"] as? Int
    else { throw PasswordCredentialStoreError.corruptRecord }
    if version == Self.recordVersion {
      _ = try read(for: binding, lease: lease)
      return .legacy
    }
    guard version == 2 else { throw PasswordCredentialStoreError.unsupportedRecordVersion(version) }
    return .record(
      try PasswordSessionRecoveryRecord.decode(
        data, binding: binding, identityURL: identityURL, apiURL: apiURL, serviceID: serviceID,
        deviceID: deviceID,
        clientID: clientID, sdkRevision: sdkRevision))
  }

  public func writeRecovery(
    _ record: PasswordSessionRecoveryRecord, for binding: PasswordAuthenticationBinding,
    expected: RecoveryLookup, lease: PasswordCredentialSessionLock
  ) throws {
    guard record.belongs(to: binding) else { throw PasswordCredentialStoreError.bindingMismatch }
    let expectedRevision: String
    if case .record(let previous) = expected {
      expectedRevision = previous.sdkRevision
    } else {
      expectedRevision = record.sdkRevision
    }
    let current = try readRecovery(
      for: binding, identityURL: record.identityURL, apiURL: record.apiURL,
      serviceID: record.serviceID, deviceID: record.deviceID, clientID: record.clientID,
      sdkRevision: expectedRevision,
      lease: lease)
    guard current == expected else { throw PasswordCredentialStoreError.recoveryConflict }
    let data = try record.encode()
    let authority = try Self.canonicalAuthority(binding.authority)
    do {
      try storage.write(
        data, service: service, account: Self.accountName(for: binding, authority: authority))
    } catch let error as PasswordCredentialStoreError {
      throw error
    } catch {
      throw Self.storageError(.write, error)
    }
    withExtendedLifetime(lease) {}
  }

  public func delete(
    for binding: PasswordAuthenticationBinding, lease: PasswordCredentialSessionLock? = nil
  ) throws {
    let held = try operationLock(for: binding, lease: lease)
    defer { withExtendedLifetime(held) {} }
    let authority = try Self.canonicalAuthority(binding.authority)
    do {
      try storage.delete(
        service: service, account: Self.accountName(for: binding, authority: authority))
    } catch let error as PasswordCredentialStoreError {
      throw error
    } catch {
      throw Self.storageError(.delete, error)
    }
  }

  private static func validToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.count <= maximumTokenBytes
  }

  static func canonicalAuthority(_ url: URL) throws -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(), !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.path.isEmpty || components.path == "/",
      components.port.map({ (1...65_535).contains($0) }) ?? true
    else {
      throw PasswordCredentialStoreError.invalidAuthority
    }
    let port = components.port.map { ":\($0)" } ?? ""
    return "https://\(host)\(port)"
  }

  private static func accountName(for binding: PasswordAuthenticationBinding, authority: String)
    -> String
  {
    "\(binding.profileID.uuidString.lowercased())/\(binding.vaultID.uuidString.lowercased())/\(binding.accountID.uuidString.lowercased())/\(authority)"
  }

  private static func storageError(
    _ operation: PasswordCredentialStoreError.Operation, _ error: Error
  )
    -> PasswordCredentialStoreError
  {
    if let status = error as? PasswordCredentialStorageFailure {
      return .storage(operation: operation, status: status.status)
    }
    return .storage(operation: operation, status: errSecInternalError)
  }
}

private struct CredentialRecord: Codable {
  let version: Int
  let profileID: UUID
  let vaultID: UUID
  let accountID: UUID
  let authority: String
  let accessToken: String
  let refreshToken: String?
  let expiresAt: Date?
}

protocol PasswordCredentialItemStorage: Sendable {
  func read(service: String, account: String) throws -> Data?
  func write(_ data: Data, service: String, account: String) throws
  func delete(service: String, account: String) throws
}

struct PasswordCredentialStorageFailure: Error, Sendable {
  let status: OSStatus
}

private struct KeychainPasswordCredentialStorage: PasswordCredentialItemStorage {
  func read(service: String, account: String) throws -> Data? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw PasswordCredentialStorageFailure(status: status)
    }
    return data
  }

  func write(_ data: Data, service: String, account: String) throws {
    var query = baseQuery(service: service, account: account)
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else {
      throw PasswordCredentialStorageFailure(status: status)
    }

    query[kSecValueData as String] = data
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    if addStatus == errSecDuplicateItem {
      var updateQuery = query
      updateQuery.removeValue(forKey: kSecValueData as String)
      let retryStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
      guard retryStatus == errSecSuccess else {
        throw PasswordCredentialStorageFailure(status: retryStatus)
      }
      return
    }
    guard addStatus == errSecSuccess else {
      throw PasswordCredentialStorageFailure(status: addStatus)
    }
  }

  func delete(service: String, account: String) throws {
    var query = baseQuery(service: service, account: account)
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PasswordCredentialStorageFailure(status: status)
    }
  }

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func noninteractiveAuthenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }
}
