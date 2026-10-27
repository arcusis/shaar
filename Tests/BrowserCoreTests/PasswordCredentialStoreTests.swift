import Foundation
import Security
import Testing

@testable import BrowserCore

private final class MemoryCredentialStorage: PasswordCredentialItemStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: Data] = [:]
  var nextFailure: Int32?
  var readOverride: Data?
  var mutateThenFailWrite: Int32?

  func read(service: String, account: String) throws -> Data? {
    try lock.withLock {
      if let status = takeFailure() { throw PasswordCredentialStorageFailure(status: status) }
      if let readOverride { return readOverride }
      return records[key(service, account)]
    }
  }

  func write(_ data: Data, service: String, account: String) throws {
    try lock.withLock {
      if let status = takeFailure() { throw PasswordCredentialStorageFailure(status: status) }
      records[key(service, account)] = data
      if let status = mutateThenFailWrite {
        mutateThenFailWrite = nil
        throw PasswordCredentialStorageFailure(status: status)
      }
    }
  }

  func delete(service: String, account: String) throws {
    try lock.withLock {
      if let status = takeFailure() { throw PasswordCredentialStorageFailure(status: status) }
      records.removeValue(forKey: key(service, account))
    }
  }

  private func takeFailure() -> Int32? {
    defer { nextFailure = nil }
    return nextFailure
  }

  private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

}

private func testBinding(
  profile: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
  vault: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
  account: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
  authority: URL = URL(string: "https://vault.example")!
) -> PasswordAuthenticationBinding {
  PasswordAuthenticationBinding(
    profileID: profile, vaultID: vault, accountID: account, authority: authority)
}

private func encodedRecord(
  version: Int = 1,
  binding: PasswordAuthenticationBinding = testBinding(),
  token: String = "synthetic-token",
  refreshToken: String? = nil
) throws -> Data {
  let components = URLComponents(url: binding.authority, resolvingAgainstBaseURL: false)!
  let record: [String: Any] = [
    "version": version,
    "profileID": binding.profileID.uuidString,
    "vaultID": binding.vaultID.uuidString,
    "accountID": binding.accountID.uuidString,
    "authority": "https://\(components.host!.lowercased())",
    "accessToken": token,
  ]
  var encodedRecord = record
  if let refreshToken { encodedRecord["refreshToken"] = refreshToken }
  return try JSONSerialization.data(withJSONObject: encodedRecord)
}

@Test func refreshTokenAndExpiryRoundtripAndLegacyTokenOnlyRecordsRemainReadable() throws {
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: "test.credentials", storage: storage)
  let binding = testBinding()
  let expiry = Date(timeIntervalSince1970: 1_800_000_000)

  try store.write(
    PasswordCredential(
      accessToken: "access-secret", refreshToken: "refresh-secret", expiresAt: expiry),
    for: binding)
  let credential = try #require(try store.read(for: binding))
  #expect(credential.accessToken == "access-secret")
  #expect(credential.refreshToken == "refresh-secret")
  #expect(credential.expiresAt == expiry)

  storage.readOverride = try encodedRecord(binding: binding)
  let legacy = try #require(try store.read(for: binding))
  #expect(legacy.accessToken == "synthetic-token")
  #expect(legacy.refreshToken == nil)
  #expect(legacy.expiresAt == nil)
}

@Test func passwordCredentialDescriptionsRedactAccessAndRefreshTokens() {
  let accessToken = "access-token-secret"
  let refreshToken = "refresh-token-secret"
  let credential = PasswordCredential(accessToken: accessToken, refreshToken: refreshToken)

  #expect(!credential.description.contains(accessToken))
  #expect(!credential.description.contains(refreshToken))
  #expect(!credential.debugDescription.contains(accessToken))
  #expect(!credential.debugDescription.contains(refreshToken))
}

@Test func readWriteUpdateAndDeleteStayBoundToProfileAndVault() throws {
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: "test.credentials", storage: storage)
  let firstProfile = testBinding()
  let secondProfile = testBinding(profile: UUID())
  let otherVault = testBinding(vault: UUID())
  let otherAccount = testBinding(account: UUID())
  let otherAuthority = testBinding(authority: URL(string: "https://self-hosted.example")!)

  try store.write(PasswordCredential(accessToken: "first"), for: firstProfile)
  try store.write(PasswordCredential(accessToken: "second-profile"), for: secondProfile)
  try store.write(PasswordCredential(accessToken: "other-vault"), for: otherVault)
  try store.write(PasswordCredential(accessToken: "other-account"), for: otherAccount)
  try store.write(PasswordCredential(accessToken: "other-authority"), for: otherAuthority)
  #expect(try store.read(for: firstProfile)?.accessToken == "first")
  #expect(try store.read(for: secondProfile)?.accessToken == "second-profile")
  #expect(try store.read(for: otherVault)?.accessToken == "other-vault")
  #expect(try store.read(for: otherAccount)?.accessToken == "other-account")
  #expect(try store.read(for: otherAuthority)?.accessToken == "other-authority")

  try store.write(PasswordCredential(accessToken: "updated"), for: firstProfile)
  #expect(try store.read(for: firstProfile)?.accessToken == "updated")
  #expect(try store.read(for: secondProfile)?.accessToken == "second-profile")
  #expect(try store.read(for: otherAccount)?.accessToken == "other-account")
  #expect(try store.read(for: otherAuthority)?.accessToken == "other-authority")
  try store.delete(for: firstProfile)
  #expect(try store.read(for: firstProfile) == nil)
  #expect(try store.read(for: secondProfile)?.accessToken == "second-profile")
  #expect(try store.read(for: otherVault)?.accessToken == "other-vault")
  #expect(try store.read(for: otherAccount)?.accessToken == "other-account")
  #expect(try store.read(for: otherAuthority)?.accessToken == "other-authority")
}

@Test func sameVaultAcrossProfilesHasIndependentCredentialRecords() throws {
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: "test.credentials", storage: storage)
  let vault = UUID()
  let account = UUID()
  let profileA = testBinding(profile: UUID(), vault: vault, account: account)
  let profileB = testBinding(profile: UUID(), vault: vault, account: account)
  try store.write(PasswordCredential(accessToken: "profile-a"), for: profileA)
  try store.write(PasswordCredential(accessToken: "profile-b"), for: profileB)

  try store.delete(for: profileA)
  #expect(try store.read(for: profileA) == nil)
  #expect(try store.read(for: profileB)?.accessToken == "profile-b")
}

@Test(arguments: [
  URL(string: "http://vault.example")!,
  URL(string: "https://user@vault.example")!,
  URL(string: "https://vault.example/path")!,
  URL(string: "https://vault.example?tenant=other")!,
  URL(string: "https://vault.example/#fragment")!,
]) func rejectsInvalidAuthorities(_ authority: URL) {
  let store = PasswordCredentialStore(
    service: "test.credentials", storage: MemoryCredentialStorage())
  #expect(throws: PasswordCredentialStoreError.invalidAuthority) {
    try store.write(
      PasswordCredential(accessToken: "synthetic"), for: testBinding(authority: authority))
  }
  #expect(throws: PasswordCredentialStoreError.invalidAuthority) {
    try store.read(for: testBinding(authority: authority))
  }
  #expect(throws: PasswordCredentialStoreError.invalidAuthority) {
    try store.delete(for: testBinding(authority: authority))
  }
}

@Test func missingCredentialReturnsNilAndDeleteIsIdempotent() throws {
  let store = PasswordCredentialStore(
    service: "test.credentials", storage: MemoryCredentialStorage())
  let binding = testBinding()
  #expect(try store.read(for: binding) == nil)
  try store.delete(for: binding)
  #expect(try store.read(for: binding) == nil)
}

@Test func rejectsInvalidAndOversizedCredentialsBeforeStorage() throws {
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: "test.credentials", storage: storage)
  #expect(throws: PasswordCredentialStoreError.invalidCredential) {
    try store.write(PasswordCredential(accessToken: ""), for: testBinding())
  }
  #expect(throws: PasswordCredentialStoreError.invalidCredential) {
    try store.write(
      PasswordCredential(accessToken: String(repeating: "x", count: 8_193)), for: testBinding())
  }
  #expect(throws: PasswordCredentialStoreError.invalidCredential) {
    try store.write(
      PasswordCredential(accessToken: "valid", refreshToken: String(repeating: "x", count: 8_193)),
      for: testBinding())
  }
  #expect(throws: PasswordCredentialStoreError.recordTooLarge) {
    try store.write(
      PasswordCredential(
        accessToken: String(repeating: "a", count: 8_192),
        refreshToken: String(repeating: "b", count: 8_192)),
      for: testBinding())
  }
  #expect(try store.read(for: testBinding()) == nil)
}

@Test func rejectsCorruptUnsupportedAndOversizedRecords() throws {
  let storage = MemoryCredentialStorage()
  let service = "test.credentials"
  let store = PasswordCredentialStore(service: service, storage: storage)
  let binding = testBinding()

  storage.readOverride = Data("not-json".utf8)
  #expect(throws: PasswordCredentialStoreError.corruptRecord) { try store.read(for: binding) }
  storage.readOverride = try encodedRecord(version: 2, binding: binding)
  #expect(throws: PasswordCredentialStoreError.unsupportedRecordVersion(2)) {
    try store.read(for: binding)
  }
  storage.readOverride = Data(repeating: 0x41, count: 16_385)
  #expect(throws: PasswordCredentialStoreError.recordTooLarge) { try store.read(for: binding) }
  storage.readOverride = try encodedRecord(binding: binding, refreshToken: "")
  #expect(throws: PasswordCredentialStoreError.corruptRecord) { try store.read(for: binding) }
}

@Test func rejectsRecordWhoseEmbeddedBindingDiffersFromLookupBinding() throws {
  let storage = MemoryCredentialStorage()
  let service = "test.credentials"
  let store = PasswordCredentialStore(service: service, storage: storage)
  let binding = testBinding()
  storage.readOverride = try encodedRecord(binding: testBinding(profile: UUID()))

  #expect(throws: PasswordCredentialStoreError.bindingMismatch) { try store.read(for: binding) }
}

@Test func reportsDeniedStorageWithRedactedBoundedDiagnostic() {
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: "test.credentials", storage: storage)
  let secret = "secret-token-that-must-not-appear"
  storage.nextFailure = Int32(errSecAuthFailed)

  do {
    try store.write(PasswordCredential(accessToken: secret), for: testBinding())
    Issue.record("Expected denied Keychain storage failure.")
  } catch {
    let diagnostic = String(describing: error)
    #expect(diagnostic.contains("write"))
    #expect(diagnostic.contains(String(errSecAuthFailed)))
    #expect(!diagnostic.contains(secret))
    #expect(diagnostic.utf8.count < 256)
  }

  try? store.write(PasswordCredential(accessToken: "stored-token"), for: testBinding())
  storage.nextFailure = Int32(errSecAuthFailed)
  #expect(
    throws: PasswordCredentialStoreError.storage(operation: .read, status: Int32(errSecAuthFailed))
  ) {
    try store.read(for: testBinding())
  }
  storage.nextFailure = Int32(errSecAuthFailed)
  #expect(
    throws: PasswordCredentialStoreError.storage(
      operation: .delete, status: Int32(errSecAuthFailed))
  ) {
    try store.delete(for: testBinding())
  }
}

@Test(
  .enabled(
    if: ProcessInfo.processInfo.environment["ARCUSIS_KEYCHAIN_PROBE"] == "1",
    "Opt-in owned Keychain mutation probe"))
func localOwnedKeychainRoundtripAndIsolation() throws {
  let namespace = PasswordCredentialProbeNamespace()
  let firstBinding = testBinding(profile: UUID(), vault: UUID(), account: UUID())
  let secondBinding = testBinding(profile: UUID(), vault: firstBinding.vaultID, account: UUID())
  let store = PasswordCredentialStore(probeNamespace: namespace)
  defer {
    for binding in [firstBinding, secondBinding] {
      do {
        try store.delete(for: binding)
      } catch {
        Issue.record("Owned Keychain probe cleanup failed: \(error)")
      }
    }
  }

  try store.write(PasswordCredential(accessToken: "probe-\(UUID().uuidString)"), for: firstBinding)
  try store.write(PasswordCredential(accessToken: "other-\(UUID().uuidString)"), for: secondBinding)
  let firstToken = try #require(store.read(for: firstBinding)?.accessToken)
  #expect(firstToken.hasPrefix("probe-"))
  #expect(try store.read(for: secondBinding)?.accessToken.hasPrefix("other-") == true)

  let updatedToken = "updated-\(UUID().uuidString)"
  try store.write(PasswordCredential(accessToken: updatedToken), for: firstBinding)
  #expect(try store.read(for: firstBinding)?.accessToken == updatedToken)
  #expect(try store.read(for: secondBinding)?.accessToken.hasPrefix("other-") == true)
  try store.delete(for: firstBinding)
  #expect(try store.read(for: firstBinding) == nil)
  #expect(try store.read(for: secondBinding)?.accessToken.hasPrefix("other-") == true)
}

private func recoveryFixture(state: PasswordSessionRecoveryRecord.State = .ready) throws
  -> PasswordSessionRecoveryRecord
{
  try PasswordSessionRecoveryRecord(
    binding: testBinding(), identityURL: URL(string: "https://vault.example/identity")!,
    apiURL: URL(string: "https://vault.example/api")!, serviceID: "synthetic-service",
    deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
    clientID: "desktop", email: "synthetic@example.invalid", sdkRevision: "test-sdk",
    kdf: Data("wrapped-kdf".utf8), wrappedAccountState: Data("wrapped-account".utf8),
    masterPasswordUnlockData: Data("wrapped-unlock".utf8),
    credential: PasswordCredential(
      accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000)),
    revision: 7, state: state)
}

private func decodeRecovery(
  _ data: Data, binding: PasswordAuthenticationBinding = testBinding(),
  identityURL: URL = URL(string: "https://vault.example/identity")!,
  clientID: String = "desktop"
) throws -> PasswordSessionRecoveryRecord {
  try PasswordSessionRecoveryRecord.decode(
    data, binding: binding, identityURL: identityURL,
    apiURL: URL(string: "https://vault.example/api")!, serviceID: "synthetic-service",
    deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
    clientID: clientID, sdkRevision: "test-sdk")
}

@Test func recoveryRecordRoundtripRetainsStateAndRedactsSecrets() throws {
  for state in [
    PasswordSessionRecoveryRecord.State.ready, .refreshInFlight,
    .reauthenticationRequired,
  ] {
    let record = try recoveryFixture(state: state)
    let decoded = try decodeRecovery(record.encode())
    #expect(decoded.state == state)
    #expect(decoded.revision == 7)
    #expect(decoded.credential == record.credential)
    #expect(decoded.wrappedAccountState == record.wrappedAccountState)
    #expect(!decoded.description.contains("synthetic-access"))
    #expect(!decoded.debugDescription.contains("synthetic-refresh"))
  }
}

@Test func recoveryRecordRejectsForeignAndMalformedData() throws {
  let bytes = try recoveryFixture().encode()
  #expect(throws: PasswordSessionRecoveryRecord.Error.bindingMismatch) {
    try decodeRecovery(bytes, binding: testBinding(account: UUID()))
  }
  #expect(throws: PasswordSessionRecoveryRecord.Error.bindingMismatch) {
    try decodeRecovery(bytes, identityURL: URL(string: "https://vault.example/other")!)
  }
  #expect(throws: PasswordSessionRecoveryRecord.Error.bindingMismatch) {
    try decodeRecovery(bytes, clientID: "other")
  }
  var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  json["version"] = 3
  #expect(throws: PasswordSessionRecoveryRecord.Error.unsupportedVersion) {
    try decodeRecovery(JSONSerialization.data(withJSONObject: json))
  }
  json["version"] = 2
  json["unexpected"] = "rejected"
  #expect(throws: PasswordSessionRecoveryRecord.Error.malformed) {
    try decodeRecovery(JSONSerialization.data(withJSONObject: json))
  }
  let canonical = try #require(String(data: bytes, encoding: .utf8))
  let duplicate = canonical.replacingOccurrences(
    of: "\"state\":\"ready\"",
    with: "\"state\":\"ready\",\"state\":\"refreshInFlight\"")
  #expect(duplicate != canonical)
  #expect(throws: PasswordSessionRecoveryRecord.Error.malformed) {
    try decodeRecovery(Data(duplicate.utf8))
  }
  #expect(throws: PasswordSessionRecoveryRecord.Error.tooLarge) {
    try decodeRecovery(Data(repeating: 0, count: 128 * 1024 + 1))
  }
  #expect(throws: PasswordSessionRecoveryRecord.Error.malformed) {
    try decodeRecovery(Data("not-json".utf8))
  }
}

@Test func recoveryStorePreservesLegacyAndRejectsStaleOrUnleasedReplacement() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let service = "test.credentials"
  let binding = testBinding()
  var lease: PasswordCredentialSessionLock? = try .acquire(
    service: service, binding: binding, applicationSupport: directory)
  defer {
    lease = nil
    try? FileManager.default.removeItem(at: directory)
  }
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: service, storage: storage)
  try store.write(PasswordCredential(accessToken: "legacy"), for: binding, lease: lease!)
  let record = try recoveryFixture()
  func read() throws -> PasswordCredentialStore.RecoveryLookup {
    try store.readRecovery(
      for: binding, identityURL: record.identityURL, apiURL: record.apiURL,
      serviceID: record.serviceID, deviceID: record.deviceID, clientID: record.clientID,
      sdkRevision: record.sdkRevision,
      lease: lease!)
  }
  #expect(try read() == .legacy)
  #expect(throws: PasswordCredentialStoreError.recoveryConflict) {
    try store.writeRecovery(record, for: binding, expected: .missing, lease: lease!)
  }
  #expect(try store.read(for: binding, lease: lease!)?.accessToken == "legacy")
  try store.writeRecovery(record, for: binding, expected: .legacy, lease: lease!)
  #expect(try read() == .record(record))
  #expect(throws: PasswordCredentialStoreError.recoveryConflict) {
    try store.write(PasswordCredential(accessToken: "would-downgrade"), for: binding, lease: lease!)
  }
  let intent = try record.replacing(
    credential: record.credential, revision: record.revision, state: .refreshInFlight)
  try store.writeRecovery(intent, for: binding, expected: .record(record), lease: lease!)
  #expect(throws: PasswordCredentialStoreError.recoveryConflict) {
    try store.writeRecovery(record, for: binding, expected: .record(record), lease: lease!)
  }
  #expect(try read() == .record(intent))
  #expect(throws: PasswordCredentialStoreError.bindingMismatch) {
    try store.writeRecovery(
      intent, for: testBinding(account: UUID()), expected: .missing, lease: lease!)
  }
}

@Test func recoveryStoreLeavesAmbiguousIntentAfterMutatingWriteThrows() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let service = "test.credentials"
  let binding = testBinding()
  var lease: PasswordCredentialSessionLock? = try .acquire(
    service: service, binding: binding, applicationSupport: directory)
  defer {
    lease = nil
    try? FileManager.default.removeItem(at: directory)
  }
  let storage = MemoryCredentialStorage()
  let store = PasswordCredentialStore(service: service, storage: storage)
  let ready = try recoveryFixture()
  try store.writeRecovery(ready, for: binding, expected: .missing, lease: lease!)
  let intent = try ready.replacing(
    credential: ready.credential, revision: ready.revision, state: .refreshInFlight)
  storage.mutateThenFailWrite = Int32(errSecAuthFailed)
  #expect(
    throws: PasswordCredentialStoreError.storage(operation: .write, status: Int32(errSecAuthFailed))
  ) {
    try store.writeRecovery(intent, for: binding, expected: .record(ready), lease: lease!)
  }
  let after = try store.readRecovery(
    for: binding, identityURL: ready.identityURL, apiURL: ready.apiURL,
    serviceID: ready.serviceID, deviceID: ready.deviceID, clientID: ready.clientID,
    sdkRevision: ready.sdkRevision,
    lease: lease!)
  #expect(after == .record(intent))
}

@Test func recoveryStoreCompetingMutationRequiresSessionLease() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let binding = testBinding()
  let store = PasswordCredentialStore(
    service: "test.credentials", storage: MemoryCredentialStorage(),
    sessionLockDirectory: directory, usesSessionLocks: true)
  var lease: PasswordCredentialSessionLock? = try store.acquireSessionLock(for: binding)
  defer {
    lease = nil
    try? FileManager.default.removeItem(at: directory)
  }
  #expect(throws: PasswordCredentialSessionLock.Error.inUse) {
    try store.write(PasswordCredential(accessToken: "synthetic"), for: binding)
  }
  try store.write(PasswordCredential(accessToken: "synthetic"), for: binding, lease: lease!)
  #expect(throws: PasswordCredentialSessionLock.Error.inUse) {
    try store.delete(for: binding)
  }
  lease = nil
  #expect(try store.read(for: binding)?.accessToken == "synthetic")
  try store.delete(for: binding)
}
