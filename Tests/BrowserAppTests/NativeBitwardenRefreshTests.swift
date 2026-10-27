import BrowserCore
import Darwin
import Foundation
import Synchronization
import Testing

@testable import ArcusisBrowser
@testable import BrowserCore

#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE && canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif
#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
  import XCTest
#endif

private final class RefreshMemoryItems: PasswordCredentialItemStorage, Sendable {
  private let records = Mutex<[String: Data]>([:])
  private let fail = Mutex(false)
  private let deleteFailure = Mutex(false)
  private let mutateThenFailAfter = Mutex<Int?>(nil)
  private let dropWriteAfter = Mutex<Int?>(nil)
  func read(service: String, account: String) throws -> Data? {
    records.withLock { $0[service + account] }
  }
  func write(_ data: Data, service: String, account: String) throws {
    if fail.withLock({ $0 }) { throw TestError.failed }
    let failAfterMutation = mutateThenFailAfter.withLock { remaining in
      guard let count = remaining else { return false }
      if count == 0 { return true }
      remaining = count - 1
      return false
    }
    let drop = dropWriteAfter.withLock { remaining in
      guard let count = remaining else { return false }
      if count == 0 { return true }
      remaining = count - 1
      return false
    }
    if !drop { records.withLock { $0[service + account] = data } }
    if failAfterMutation { throw TestError.failed }
  }
  func delete(service: String, account: String) throws {
    if deleteFailure.withLock({ $0 }) { throw TestError.failed }
    _ = records.withLock { $0.removeValue(forKey: service + account) }
  }
  func onlyRecord() -> Data? {
    records.withLock { values in values.count == 1 ? values.values.first : nil }
  }
  func failWrites() { fail.withLock { $0 = true } }
  func failDeletes() { deleteFailure.withLock { $0 = true } }
  func failAfterOneWrite() { mutateThenFailAfter.withLock { $0 = 1 } }
  func failAfterMutation() { mutateThenFailAfter.withLock { $0 = 0 } }
  func dropAfterOneWrite() { dropWriteAfter.withLock { $0 = 1 } }
  enum TestError: Error { case failed }
}

@MainActor private final class RefreshHarness {
  let directory: URL
  let binding: PasswordAuthenticationBinding
  var lease: PasswordCredentialSessionLock!
  let store: PasswordCredentialStore
  let storage: RefreshMemoryItems
  let initial: PasswordSessionRecoveryRecord
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var responses = 0
  var published: [String] = []
  var persistedAtPublication = false
  var revoked = 0
  var continuation: CheckedContinuation<NativeBitwardenRefreshResponse, Error>?

  init(
    expiresIn: TimeInterval = -1, usesSessionLocks: Bool = false,
    flushFile: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
  ) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    binding = PasswordAuthenticationBinding(
      profileID: UUID(), vaultID: UUID(), accountID: UUID(),
      authority: URL(string: "https://vault.example")!)
    lease = try PasswordCredentialSessionLock.acquire(
      service: "refresh-test", binding: binding, applicationSupport: directory,
      flushFile: flushFile)
    storage = RefreshMemoryItems()
    store = PasswordCredentialStore(
      service: "refresh-test", storage: storage, sessionLockDirectory: directory,
      usesSessionLocks: usesSessionLocks)
    initial = try PasswordSessionRecoveryRecord(
      binding: binding, identityURL: URL(string: "https://vault.example/identity")!,
      apiURL: URL(string: "https://vault.example/api")!, serviceID: "synthetic-service",
      deviceID: UUID(),
      clientID: "desktop", email: "test@example.invalid", sdkRevision: "synthetic",
      kdf: Data("wrapped-kdf".utf8), wrappedAccountState: Data("wrapped-state".utf8),
      masterPasswordUnlockData: Data("wrapped-unlock".utf8),
      credential: PasswordCredential(
        accessToken: "old", refreshToken: "old-refresh",
        expiresAt: now.addingTimeInterval(expiresIn)),
      revision: 1, state: .ready)
    try store.writeRecovery(initial, for: binding, expected: .missing, lease: lease)
  }

  func cleanup() {
    lease = nil
    do {
      var probe: PasswordCredentialSessionLock? = try .acquire(
        service: "refresh-test", binding: binding, applicationSupport: directory)
      guard probe != nil else {
        Issue.record("Fixture lock unavailable during cleanup")
        return
      }
      probe = nil
      try FileManager.default.removeItem(at: directory)
    } catch {
      Issue.record("Fixture lock remained held during cleanup")
    }
  }

  func token(
    account: UUID? = nil, client: String = "desktop", expiresIn: TimeInterval = 3600
  ) throws -> String {
    let payload = try JSONSerialization.data(withJSONObject: [
      "sub": (account ?? binding.accountID).uuidString,
      "client_id": client, "exp": now.timeIntervalSince1970 + expiresIn,
    ])
    let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).c2ln"
  }

  func read() throws -> PasswordCredentialStore.RecoveryLookup {
    try store.readRecovery(
      for: binding, identityURL: initial.identityURL, apiURL: initial.apiURL,
      serviceID: initial.serviceID, deviceID: initial.deviceID, clientID: initial.clientID,
      sdkRevision: initial.sdkRevision,
      lease: lease)
  }

  func coordinator(deferred: Bool = false, result: NativeBitwardenRefreshResponse) throws
    -> NativeBitwardenRefreshCoordinator
  {
    try NativeBitwardenRefreshCoordinator(
      binding: binding, record: initial, store: store, lease: lease, now: { self.now },
      transport: { _ in
        self.responses += 1
        if deferred {
          return try await withCheckedThrowingContinuation { self.continuation = $0 }
        }
        return result
      }, isOwner: { true },
      publish: { token in
        if case .record(let saved) = try? self.read() {
          self.persistedAtPublication =
            saved.state == .ready && saved.credential.accessToken == token
        }
        self.published.append(token)
      },
      revoke: { self.revoked += 1 })
  }
}

#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE && canImport(ArcusisBitwardenSDK)
  private actor DelayedRefreshBackend: NativeBitwardenRefreshBackend {
    let account = UUID()
    let session = UUID()
    let provider = NativeBitwardenTokenProvider()
    var device = UUID()
    var endpoint: BitwardenServerConfiguration = .init(region: .us)
    var continuation: CheckedContinuation<NativeBitwardenRefreshResponse, Error>?
    var loginCount = 0
    var restoreCount = 0
    var claimExpiry: Date?
    var loginContinuation: CheckedContinuation<Void, Never>?
    let deferLogin: Bool
    let sdkExtra: TimeInterval
    let jwtLead: TimeInterval
    var isAvailable: Bool { true }

    init(sdkExtra: TimeInterval = 0, deferLogin: Bool = false, jwtLead: TimeInterval = 30) {
      self.sdkExtra = sdkExtra
      self.deferLogin = deferLogin
      self.jwtLead = jwtLead
    }

    func token(expires: Date) throws -> String {
      let data = try JSONSerialization.data(withJSONObject: [
        "sub": account.uuidString, "client_id": NativeBitwardenLoginRequestMetadata.clientID,
        "exp": expires.timeIntervalSince1970,
      ])
      let value = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      return "e30.\(value).c2ln"
    }

    func login(
      server: BitwardenServerConfiguration, email: String, password: String, deviceID: UUID,
      secondFactor: NativeBitwardenSecondFactor?
    ) async throws -> NativeBitwardenLoginResult {
      loginCount += 1
      endpoint = server
      device = deviceID
      if deferLogin { await withCheckedContinuation { loginContinuation = $0 } }
      return .authenticated(.init(id: session, accountID: account))
    }
    func initializeCrypto(candidateID: UUID, password: String) async throws
      -> NativeBitwardenEstablishedSession
    {
      let expiry = Date().addingTimeInterval(jwtLead)
      claimExpiry = expiry
      return NativeBitwardenEstablishedSession(
        id: session, accountID: account,
        credential: PasswordCredential(
          accessToken: try token(expires: expiry), refreshToken: "synthetic-refresh",
          expiresAt: expiry.addingTimeInterval(sdkExtra)), tokenProvider: provider)
    }
    func recoveryContext(sessionID: UUID) async throws -> NativeBitwardenRecoveryContext {
      let endpoints = try endpoint.endpoints()
      return NativeBitwardenRecoveryContext(
        email: "fixture@example.invalid", identityURL: endpoints.identityURL,
        apiURL: endpoints.apiURL, deviceID: device, kdf: Data("kdf".utf8),
        wrappedAccountState: Data("wrapped".utf8),
        masterPasswordUnlockData: Data("unlock".utf8))
    }
    func restoreLocked(record: PasswordSessionRecoveryRecord, server: BitwardenServerConfiguration)
      async throws -> UUID
    {
      restoreCount += 1
      throw NativeBitwardenBackendError.staleSession
    }
    func unlockRestored(sessionID: UUID, record: PasswordSessionRecoveryRecord, password: String)
      async throws -> NativeBitwardenEstablishedSession
    { throw NativeBitwardenBackendError.staleSession }
    func refresh(sessionID: UUID, record: PasswordSessionRecoveryRecord) async throws
      -> NativeBitwardenRefreshResponse
    {
      try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release() throws {
      let value = NativeBitwardenRefreshResponse(
        accessToken: try token(expires: Date().addingTimeInterval(3600)),
        refreshToken: "replacement", expiresIn: 3600)
      continuation?.resume(returning: value)
      continuation = nil
    }
    func waiting() -> Bool { continuation != nil }
    func count() -> Int { loginCount }
    func restoredCount() -> Int { restoreCount }
    func loginWaiting() -> Bool { loginContinuation != nil }
    func releaseLogin() {
      loginContinuation?.resume()
      loginContinuation = nil
    }
    func tokenValue() async -> String? { await provider.getAccessToken() }
    func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot { .empty }
    func lock(sessionID: UUID) async -> Bool { true }
    func discard(sessionID: UUID) async {}
  }
#endif

@Suite @MainActor struct NativeBitwardenRefreshTests {
  @Test func desktopEntryMatchesFixtureBuildMode() {
    #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
      #expect(!ArcusisBrowserMain.desktopEntryAllowed)
    #else
      #expect(ArcusisBrowserMain.desktopEntryAllowed)
    #endif
  }

  #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE && canImport(ArcusisBitwardenSDK)
    private struct PublicCryptoVector: Decodable {
      let email: String
      let userID: String
      let currentPassword: String
      let privateKey: String
      let wrappedUserKey: String
      let iterations: UInt32
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARCUSIS_REFRESH_VECTOR"] != nil))
    func actualSDKRestoresLockedAndRequiresCorrectPasswordWithoutNetwork() async throws {
      let encoded = try #require(ProcessInfo.processInfo.environment["ARCUSIS_REFRESH_VECTOR"])
      let data = try #require(Data(base64Encoded: encoded))
      let vector = try JSONDecoder().decode(PublicCryptoVector.self, from: data)
      let account = try #require(UUID(uuidString: vector.userID))
      let server = BitwardenServerConfiguration(
        region: .custom, customBaseURL: "https://fixture.example")
      let endpoints = try server.endpoints()
      let binding = PasswordAuthenticationBinding(
        profileID: UUID(), vaultID: UUID(), accountID: account,
        authority: endpoints.credentialAuthority)
      let kdf = Kdf.pbkdf2(iterations: vector.iterations)
      let wrapped = WrappedAccountCryptographicState.v1(privateKey: vector.privateKey)
      let unlock = MasterPasswordUnlockData(
        kdf: kdf, masterKeyWrappedUserKey: vector.wrappedUserKey,
        salt: vector.email, containedKeyId: nil)
      let encoder = JSONEncoder()
      let record = try PasswordSessionRecoveryRecord(
        binding: binding, identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
        serviceID: endpoints.stableServiceID, deviceID: UUID(), clientID: "desktop",
        email: vector.email, sdkRevision: "synthetic",
        kdf: encoder.encode(kdf), wrappedAccountState: encoder.encode(wrapped),
        masterPasswordUnlockData: encoder.encode(unlock),
        credential: PasswordCredential(
          accessToken: "synthetic", refreshToken: "synthetic",
          expiresAt: Date().addingTimeInterval(3600)),
        revision: 1, state: .ready)
      let backend = NativeBitwardenSDKBackend()
      let first = try await backend.restoreLocked(record: record, server: server)
      do {
        _ = try await backend.syncVault(sessionID: first)
        Issue.record("locked candidate accepted sync")
      } catch {}
      do {
        _ = try await backend.unlockRestored(
          sessionID: first, record: record, password: "wrong synthetic password")
        Issue.record("wrong password unlocked candidate")
      } catch {}
      let unlocked = try await backend.unlockRestored(
        sessionID: first, record: record, password: vector.currentPassword)
      #expect(unlocked.accountID == account)
      #expect(await unlocked.tokenProvider.getAccessToken() == nil)
      #expect(await backend.lock(sessionID: first))
      await backend.discard(sessionID: first)
      let secondBackend = NativeBitwardenSDKBackend()
      let second = try await secondBackend.restoreLocked(record: record, server: server)
      let restored = try await secondBackend.unlockRestored(
        sessionID: second, record: record, password: vector.currentPassword)
      #expect(restored.accountID == account)
      #expect(await restored.tokenProvider.getAccessToken() == nil)
      _ = await secondBackend.lock(sessionID: second)
      await secondBackend.discard(sessionID: second)
    }

    @Test func actualSDKRejectsEmptyRefreshBeforeNetwork() async {
      _ = NativeBitwardenSDKBackend()
      let client = Client(
        tokenProvider: NativeBitwardenTokenProvider(),
        settings: ClientSettings(
          identityUrl: "https://identity.invalid", apiUrl: "https://api.invalid",
          userAgent: "synthetic", deviceType: .sdk, deviceIdentifier: UUID().uuidString,
          bitwardenClientVersion: "0.1.0", bitwardenPackageType: "desktop"),
        managedSettings: ManagedSettingsBindingClient())
      do {
        _ = try await client.auth().refreshPasswordManagerToken(
          refreshToken: "", clientId: "desktop", email: "synthetic@example.invalid",
          kdf: .pbkdf2(iterations: 600_000))
        Issue.record("SDK accepted empty refresh input")
      } catch let error as RefreshError {
        #expect(error == .InvalidInput)
      } catch {
        Issue.record("Unexpected SDK error category")
      }
    }
  #endif
  @Test func refreshPersistsBeforePublishingAndRetainsOmittedToken() async throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    let token = try h.token()
    var coordinator: NativeBitwardenRefreshCoordinator! = try h.coordinator(
      result: NativeBitwardenRefreshResponse(accessToken: token, refreshToken: nil, expiresIn: 3600)
    )
    defer { coordinator = nil }
    let result = try await coordinator.ensureFresh()
    #expect(result.refreshToken == "old-refresh")
    #expect(h.published == [token])
    #expect(h.persistedAtPublication)
    guard case .record(let stored) = try h.read() else {
      Issue.record("missing record")
      return
    }
    #expect(stored.state == .ready)
    #expect(stored.revision == 2)
    #expect(stored.credential == result)
    _ = try await coordinator.ensureFresh(force: true, observedRevision: 1)
    #expect(h.responses == 1)
  }

  @Test func expirySkewRefreshesOnlyAtOrInsideThreshold() async throws {
    let fresh = try RefreshHarness(expiresIn: 61)
    defer { fresh.cleanup() }
    var first: NativeBitwardenRefreshCoordinator! = try fresh.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try fresh.token(), refreshToken: nil, expiresIn: 3600))
    defer { first = nil }
    _ = try await first.ensureFresh()
    #expect(fresh.responses == 0)
    #expect(fresh.published.isEmpty)

    let near = try RefreshHarness(expiresIn: 60)
    defer { near.cleanup() }
    var second: NativeBitwardenRefreshCoordinator! = try near.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try near.token(), refreshToken: nil, expiresIn: 3600))
    defer { second = nil }
    _ = try await second.ensureFresh()
    #expect(near.responses == 1)
    #expect(near.published.count == 1)
  }

  @Test func previousRevisionReplacementRequiresExactOwnedRecord() throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    let replacement = try PasswordSessionRecoveryRecord(
      binding: h.binding, identityURL: h.initial.identityURL, apiURL: h.initial.apiURL,
      serviceID: h.initial.serviceID, deviceID: h.initial.deviceID,
      clientID: h.initial.clientID, email: h.initial.email, sdkRevision: "new-synthetic",
      kdf: h.initial.kdf, wrappedAccountState: h.initial.wrappedAccountState,
      masterPasswordUnlockData: h.initial.masterPasswordUnlockData,
      credential: h.initial.credential, revision: 2, state: .reauthenticationRequired)
    let stale = try h.initial.replacing(
      credential: h.initial.credential, revision: 2, state: .ready)
    #expect(throws: PasswordCredentialStoreError.recoveryConflict) {
      try h.store.writeRecovery(
        replacement, for: h.binding, expected: .record(stale), lease: h.lease)
    }
    #expect(try h.read() == .record(h.initial))
    try h.store.writeRecovery(
      replacement, for: h.binding, expected: .record(h.initial), lease: h.lease)
    #expect(throws: PasswordSessionRecoveryRecord.Error.bindingMismatch) { try h.read() }
    let saved = try h.store.readRecovery(
      for: h.binding, identityURL: replacement.identityURL, apiURL: replacement.apiURL,
      serviceID: replacement.serviceID, deviceID: replacement.deviceID,
      clientID: replacement.clientID, sdkRevision: replacement.sdkRevision, lease: h.lease)
    #expect(saved == .record(replacement))
  }

  @Test func restoredClampedExpiryRefreshesBeforePublishingExpiredAccess() async throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    let expiredToken = try h.token(expiresIn: -30)
    let expired = PasswordCredential(
      accessToken: expiredToken, refreshToken: "old-refresh",
      expiresAt: h.now.addingTimeInterval(-30))
    let restored = try h.initial.replacing(credential: expired, revision: 1, state: .ready)
    try NativeBitwardenRefreshCoordinator.validateStored(restored)
    try h.store.writeRecovery(
      restored, for: h.binding, expected: .record(h.initial), lease: h.lease)
    let replacement = NativeBitwardenRefreshResponse(
      accessToken: try h.token(), refreshToken: "new-refresh", expiresIn: 3600)
    var coordinator: NativeBitwardenRefreshCoordinator? = try NativeBitwardenRefreshCoordinator(
      binding: h.binding, record: restored, store: h.store, lease: h.lease, now: { h.now },
      transport: { _ in
        h.responses += 1
        return try await withCheckedThrowingContinuation { h.continuation = $0 }
      }, isOwner: { true }, publish: { h.published.append($0) }, revoke: {})
    let task = Task { [coordinator] in try await coordinator!.ensureFresh() }
    for _ in 0..<100 where h.continuation == nil { await Task.yield() }
    let continuation = try #require(h.continuation)
    #expect(h.responses == 1)
    #expect(h.published.isEmpty)
    continuation.resume(returning: replacement)
    let credential = try await task.value
    #expect(credential.accessToken == replacement.accessToken)
    #expect(h.published == [replacement.accessToken])
    coordinator = nil
  }

  @Test func concurrentRefreshPublishesOneSharedRotation() async throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    let response = NativeBitwardenRefreshResponse(
      accessToken: try h.token(), refreshToken: "rotated", expiresIn: 3600)
    var coordinator: NativeBitwardenRefreshCoordinator! = try h.coordinator(
      deferred: true, result: response)
    defer { coordinator = nil }
    let first = Task { [coordinator] in try await coordinator!.ensureFresh() }
    for _ in 0..<100 where h.continuation == nil { await Task.yield() }
    let continuation = try #require(h.continuation)
    let second = Task { [coordinator] in try await coordinator!.ensureFresh() }
    await Task.yield()
    continuation.resume(returning: response)
    let a = try await first.value
    let b = try await second.value
    #expect(a == b)
    #expect(a.refreshToken == "rotated")
    #expect(h.responses == 1)
    #expect(h.published.count == 1)
    #expect(h.persistedAtPublication)
  }

  @Test func concurrentRefreshCoalescesAndInvalidationRejectsLateResponse() async throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    let token = try h.token()
    let response = NativeBitwardenRefreshResponse(
      accessToken: token, refreshToken: "rotated", expiresIn: 3600)
    var coordinator: NativeBitwardenRefreshCoordinator! = try h.coordinator(
      deferred: true, result: response)
    defer { coordinator = nil }
    let first = Task { [coordinator] in try await coordinator!.ensureFresh() }
    for _ in 0..<100 where h.continuation == nil { await Task.yield() }
    let continuation = try #require(h.continuation)
    let second = Task { [coordinator] in try await coordinator!.ensureFresh() }
    await Task.yield()
    guard case .record(let intent) = try h.read() else {
      Issue.record("missing intent")
      return
    }
    #expect(intent.state == .refreshInFlight)
    #expect(h.responses == 1)
    coordinator.invalidate()
    continuation.resume(returning: response)
    do {
      _ = try await first.value
      Issue.record("stale result published")
    } catch {}
    do {
      _ = try await second.value
      Issue.record("stale result published")
    } catch {}
    #expect(h.published.isEmpty)
    #expect(h.revoked == 1)
    #expect(try h.read() == .record(intent))
  }

  @Test func reproduceDisconnectWithCancellationIgnoringTransport() async throws {
    let h = try RefreshHarness(usesSessionLocks: true)
    defer { h.cleanup() }
    let response = NativeBitwardenRefreshResponse(
      accessToken: try h.token(), refreshToken: "rotated", expiresIn: 3600)
    var coordinator: NativeBitwardenRefreshCoordinator? = try h.coordinator(
      deferred: true, result: response)
    let inFlight = Task { [coordinator] in try await coordinator!.ensureFresh() }
    for _ in 0..<100 where h.continuation == nil { await Task.yield() }
    let continuation = try #require(h.continuation)
    coordinator?.invalidate()
    coordinator = nil
    h.lease = nil
    #expect(throws: PasswordCredentialSessionLock.Error.inUse) {
      try h.store.delete(for: h.binding)
    }
    continuation.resume(returning: response)
    _ = try? await inFlight.value
    #expect(h.storage.onlyRecord() != nil)
    #expect(h.published.isEmpty)
  }

  #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE && canImport(ArcusisBitwardenSDK)
    @Test(arguments: [0, 1, 2])
    func initialPreferenceFailureCreatesNoCredential(failureStage: Int) async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appending(path: "preferences.json")
      let prefs =
        failureStage > 0
        ? BrowserPreferencesStore(
          fileURL: file,
          syncDirectory: { path in
            if failureStage == 1
              || path.standardizedFileURL.path
                == directory.deletingLastPathComponent().standardizedFileURL.path
            {
              throw BrowserPreferencesStore.DurableVaultSaveError.writeFailed
            }
          }) : BrowserPreferencesStore()
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "initial-pref-failure", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let backend = DelayedRefreshBackend()
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where controller.status != "Could not save session securely; sign in again."
      {
        await Task.yield()
      }
      #expect(controller.status == "Could not save session securely; sign in again.")
      #expect(items.onlyRecord() == nil)
      #expect(prefs.nativeVaultPreferences(for: profile).accountID == nil)
      #expect(await backend.tokenValue() == nil)
      if failureStage > 0 {
        let reloaded = BrowserPreferencesStore(fileURL: file)
        #expect(reloaded.nativeVaultPreferences(for: profile).accountID == backend.account)
      }
    }

    @Test(arguments: [false, true])
    func initialCredentialFailureLeavesDurablePointerAndFence(readbackFailure: Bool) async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appending(path: "preferences.json")
      let prefs = BrowserPreferencesStore(fileURL: file)
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let items = RefreshMemoryItems()
      if readbackFailure { items.dropAfterOneWrite() } else { items.failAfterMutation() }
      let store = PasswordCredentialStore(
        service: "initial-write-failure", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let backend = DelayedRefreshBackend()
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where controller.status != "Could not save session securely; sign in again."
      {
        await Task.yield()
      }
      #expect(controller.status == "Could not save session securely; sign in again.")
      let saved = BrowserPreferencesStore(fileURL: file).nativeVaultPreferences(for: profile)
      #expect(saved.accountID == backend.account)
      #expect(items.onlyRecord() != nil)
      #expect(await backend.tokenValue() == nil)
      let binding = PasswordAuthenticationBinding(
        profileID: profile, vaultID: saved.vaultID, accountID: backend.account,
        authority: try saved.server.endpoints().credentialAuthority)
      var lease: PasswordCredentialSessionLock? = try store.acquireSessionLock(for: binding)
      #expect(try #require(lease).hasPendingRotation())
      lease = nil
    }

    @Test func initialJWTClampIsPersistedBeforePublication() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let prefs = BrowserPreferencesStore(fileURL: directory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "initial-clamp", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let backend = DelayedRefreshBackend(sdkExtra: 290)
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
      #expect(await backend.waiting())
      let saved = prefs.nativeVaultPreferences(for: profile)
      let endpoints = try saved.server.endpoints()
      let binding = PasswordAuthenticationBinding(
        profileID: profile, vaultID: saved.vaultID, accountID: backend.account,
        authority: endpoints.credentialAuthority)
      let record = try PasswordSessionRecoveryRecord.decode(
        #require(items.onlyRecord()), binding: binding, identityURL: endpoints.identityURL,
        apiURL: endpoints.apiURL, serviceID: endpoints.stableServiceID, deviceID: saved.deviceID,
        clientID: NativeBitwardenLoginRequestMetadata.clientID,
        sdkRevision: NativeBitwardenController.recoverySDKRevision)
      let expiry = try #require(record.credential.expiresAt)
      let claimExpiry = try #require(await backend.claimExpiry)
      #expect(expiry <= claimExpiry)
      #expect(claimExpiry.timeIntervalSince(expiry) < 2)
      #expect(await backend.tokenValue() == record.credential.accessToken)
      controller.disconnect()
      try await backend.release()
      for _ in 0..<500 where controller.status == "Removing credentials…" { await Task.yield() }
    }

    @Test func expiredLegacyJWTWithLaterSDKExpiryCannotRestoreOrPublish() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let prefs = BrowserPreferencesStore(fileURL: directory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let backend = DelayedRefreshBackend()
      let original = prefs.nativeVaultPreferences(for: profile)
      try prefs.persistNativeVaultAccountID(backend.account, for: profile, expected: original)
      let saved = prefs.nativeVaultPreferences(for: profile)
      let endpoints = try saved.server.endpoints()
      let binding = PasswordAuthenticationBinding(
        profileID: profile, vaultID: saved.vaultID, accountID: backend.account,
        authority: endpoints.credentialAuthority)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "legacy-expiry", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let jwtExpiry = Date().addingTimeInterval(-30)
      let token = try await backend.token(expires: jwtExpiry)
      let record = try PasswordSessionRecoveryRecord(
        binding: binding, identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
        serviceID: endpoints.stableServiceID, deviceID: saved.deviceID,
        clientID: NativeBitwardenLoginRequestMetadata.clientID, email: "fixture@example.invalid",
        sdkRevision: NativeBitwardenController.recoverySDKRevision, kdf: Data("kdf".utf8),
        wrappedAccountState: Data("wrapped".utf8), masterPasswordUnlockData: Data("unlock".utf8),
        credential: PasswordCredential(
          accessToken: token, refreshToken: "synthetic",
          expiresAt: jwtExpiry.addingTimeInterval(290)),
        revision: 0, state: .ready)
      var lease: PasswordCredentialSessionLock? = try store.acquireSessionLock(for: binding)
      try store.writeRecovery(record, for: binding, expected: .missing, lease: #require(lease))
      lease = nil
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where controller.isLoading { await Task.yield() }
      #expect(!controller.hasConnectedSession)
      #expect(await backend.restoredCount() == 0)
      #expect(await backend.count() == 0)
      #expect(await backend.tokenValue() == nil)
    }

    @Test func sdk6RecordRequiresExplicitNewAuthenticationBeforeSDK7Replacement() async throws {
      let previousRevision =
        "sdk6-391b8b63b97980b99b661dab487f18e610aa902c7fe07b26e0aca3ca8a697150"
      #expect(NativeBitwardenController.recoverySDKRevision != previousRevision)
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let prefs = BrowserPreferencesStore(fileURL: directory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let backend = DelayedRefreshBackend(deferLogin: true)
      let original = prefs.nativeVaultPreferences(for: profile)
      try prefs.persistNativeVaultAccountID(backend.account, for: profile, expected: original)
      let saved = prefs.nativeVaultPreferences(for: profile)
      let endpoints = try saved.server.endpoints()
      let binding = PasswordAuthenticationBinding(
        profileID: profile, vaultID: saved.vaultID, accountID: backend.account,
        authority: endpoints.credentialAuthority)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "sdk6-reauthentication", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let expiry = Date().addingTimeInterval(3600)
      let oldToken = try await backend.token(expires: expiry)
      let record = try PasswordSessionRecoveryRecord(
        binding: binding, identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
        serviceID: endpoints.stableServiceID, deviceID: saved.deviceID,
        clientID: NativeBitwardenLoginRequestMetadata.clientID, email: "fixture@example.invalid",
        sdkRevision: previousRevision, kdf: Data("kdf".utf8),
        wrappedAccountState: Data("wrapped".utf8), masterPasswordUnlockData: Data("unlock".utf8),
        credential: PasswordCredential(
          accessToken: oldToken, refreshToken: "old-synthetic", expiresAt: expiry),
        revision: 2, state: .ready)
      var lease: PasswordCredentialSessionLock? = try store.acquireSessionLock(for: binding)
      try store.writeRecovery(record, for: binding, expected: .missing, lease: #require(lease))
      lease = nil
      let oldBytes = try #require(items.onlyRecord())
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !(await backend.loginWaiting()) { await Task.yield() }
      #expect(await backend.loginWaiting())
      #expect(!controller.hasConnectedSession)
      #expect(await backend.count() == 1)
      #expect(await backend.restoredCount() == 0)
      #expect(await backend.tokenValue() == nil)
      #expect(items.onlyRecord() == oldBytes)
      await backend.releaseLogin()
      for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
      #expect(await backend.waiting())
      #expect(await backend.count() == 1)
      #expect(await backend.restoredCount() == 0)
      let published = try #require(await backend.tokenValue())
      #expect(published != oldToken)
      let newRecord = try PasswordSessionRecoveryRecord.decode(
        #require(items.onlyRecord()), binding: binding, identityURL: endpoints.identityURL,
        apiURL: endpoints.apiURL, serviceID: endpoints.stableServiceID, deviceID: saved.deviceID,
        clientID: NativeBitwardenLoginRequestMetadata.clientID,
        sdkRevision: NativeBitwardenController.recoverySDKRevision)
      #expect(newRecord.state == .refreshInFlight)
      controller.disconnect()
      try await backend.release()
      for _ in 0..<500 where controller.status == "Removing credentials…" { await Task.yield() }
      #expect(controller.status == "Disconnected")
      #expect(items.onlyRecord() == nil)
      #expect(await backend.tokenValue() == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func serverChangeRetainsPointerUntilOwnedDeletion(delayed: Bool, deleteFails: Bool) async throws
    {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let file = directory.appending(path: "preferences.json")
      let prefs = BrowserPreferencesStore(fileURL: file)
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "server-change", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let backend = DelayedRefreshBackend(jwtLead: delayed ? 30 : 3600)
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      if delayed {
        for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
        #expect(await backend.waiting())
      } else {
        for _ in 0..<500 where !controller.syncStatus.hasPrefix("Synced") { await Task.yield() }
        #expect(controller.syncStatus.hasPrefix("Synced"))
      }
      let before = prefs.nativeVaultPreferences(for: profile)
      let original = try #require(items.onlyRecord())
      if deleteFails { items.failDeletes() }
      controller.setServer(.init(region: .eu))
      #expect(prefs.nativeVaultPreferences(for: profile) == before)
      #expect(BrowserPreferencesStore(fileURL: file).nativeVaultPreferences(for: profile) == before)
      #expect(items.onlyRecord() == original)
      #expect(controller.status == "Removing previous credentials…")
      #expect(await backend.tokenValue() == nil)
      if delayed {
        controller.email = "fixture@example.invalid"
        controller.masterPassword = "synthetic"
        controller.connect()
        #expect(controller.status == "Credential removal is still pending.")
        #expect(await backend.count() == 1)
        try await backend.release()
      }
      let desired =
        deleteFails ? "Could not remove previous credentials securely." : "Not connected"
      for _ in 0..<500 where controller.status != desired { await Task.yield() }
      #expect(controller.status == desired)
      if deleteFails {
        #expect(prefs.nativeVaultPreferences(for: profile) == before)
        #expect(items.onlyRecord() == original)
      } else {
        let after = prefs.nativeVaultPreferences(for: profile)
        #expect(after.server == .init(region: .eu))
        #expect(after.accountID == nil)
        #expect(after.vaultID != before.vaultID)
        #expect(items.onlyRecord() == nil)
        #expect(
          BrowserPreferencesStore(fileURL: file).nativeVaultPreferences(for: profile) == after)
      }
      #expect(await backend.tokenValue() == nil)
    }

    @Test func serverChangeReportsPreferenceFailureAfterDeletion() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      var failSync = false
      let prefs = BrowserPreferencesStore(
        fileURL: directory.appending(path: "preferences.json"),
        syncDirectory: { _ in
          if failSync { throw BrowserPreferencesStore.DurableVaultSaveError.writeFailed }
        })
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "server-pref-failure", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let backend = DelayedRefreshBackend(jwtLead: 3600)
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !controller.syncStatus.hasPrefix("Synced") { await Task.yield() }
      #expect(controller.syncStatus.hasPrefix("Synced"))
      let before = prefs.nativeVaultPreferences(for: profile)
      failSync = true
      controller.setServer(.init(region: .eu))
      for _ in 0..<500 where controller.status != "Could not save server securely." {
        await Task.yield()
      }
      #expect(controller.status == "Could not save server securely.")
      #expect(prefs.nativeVaultPreferences(for: profile) == before)
      #expect(items.onlyRecord() == nil)
      #expect(await backend.tokenValue() == nil)
    }

    @Test(arguments: [false, true])
    func staleCleanupCannotClearAlreadyChangedAccount(serverChange: Bool) async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let prefs = BrowserPreferencesStore(fileURL: directory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "stale-existing-account", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let backend = DelayedRefreshBackend()
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
      #expect(await backend.waiting())
      let original = try #require(items.onlyRecord())
      let otherAccount = UUID()
      prefs.setNativeVaultAccountID(otherAccount, for: profile)
      if serverChange { controller.setServer(.init(region: .eu)) } else { controller.disconnect() }
      try await backend.release()
      let expectedStatus =
        serverChange
        ? "Could not remove previous credentials securely."
        : "Could not remove credentials securely."
      for _ in 0..<500 where controller.status != expectedStatus { await Task.yield() }
      #expect(controller.status == expectedStatus)
      #expect(prefs.nativeVaultPreferences(for: profile).accountID == otherAccount)
      #expect(items.onlyRecord() == original)
      #expect(await backend.tokenValue() == nil)
    }

    @Test(arguments: [false, true])
    func disconnectDrainsDelayedRefreshBeforeOwnedDeletion(disable: Bool) async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "disconnect-test", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let prefs = BrowserPreferencesStore(fileURL: directory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let backend = DelayedRefreshBackend()
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
      #expect(await backend.waiting())
      let account = backend.account
      let saved = prefs.nativeVaultPreferences(for: profile)
      #expect(saved.accountID == account)
      let binding = PasswordAuthenticationBinding(
        profileID: profile, vaultID: saved.vaultID, accountID: account,
        authority: try saved.server.endpoints().credentialAuthority)
      if disable { controller.setEnabled(false) } else { controller.disconnect() }
      #expect(!controller.hasConnectedSession)
      #expect(await backend.tokenValue() == nil)
      #expect(controller.status == "Removing credentials…")
      #expect(items.onlyRecord() != nil)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      #expect(await backend.count() == 1)
      #expect(controller.status == "Credential removal is still pending.")
      try await backend.release()
      for _ in 0..<500 where prefs.nativeVaultPreferences(for: profile).accountID != nil {
        await Task.yield()
      }
      #expect(items.onlyRecord() == nil)
      #expect(prefs.nativeVaultPreferences(for: profile).accountID == nil)
      #expect(controller.status == (disable ? "Off" : "Disconnected"))
      #expect(await backend.tokenValue() == nil)
      var markerLease: PasswordCredentialSessionLock?
      for _ in 0..<500 where markerLease == nil {
        markerLease = try? store.acquireSessionLock(for: binding)
        if markerLease == nil { await Task.yield() }
      }
      #expect(try #require(markerLease).hasPendingRotation())
      markerLease = nil
    }

    @Test func staleCleanupDoesNotDeleteAfterExternalRebind() async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "disconnect-rebind-test", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let prefs = BrowserPreferencesStore(fileURL: directory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let backend = DelayedRefreshBackend()
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
      #expect(await backend.waiting())
      controller.disconnect()
      let original = try #require(items.onlyRecord())
      prefs.setNativeVaultServer(.init(region: .eu), for: profile)
      try await backend.release()
      for _ in 0..<500 where controller.status != "Could not remove credentials securely." {
        await Task.yield()
      }
      #expect(controller.status == "Could not remove credentials securely.")
      #expect(items.onlyRecord() == original)
      #expect(prefs.nativeVaultPreferences(for: profile).server == .init(region: .eu))
      #expect(await backend.tokenValue() == nil)
    }

    @Test(arguments: [false, true])
    func disconnectReportsDeleteAndPreferenceFailure(preferenceFailure: Bool) async throws {
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      let prefsDirectory = directory.appending(path: "prefs")
      try FileManager.default.createDirectory(
        at: prefsDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let items = RefreshMemoryItems()
      let store = PasswordCredentialStore(
        service: "disconnect-failure-test", storage: items, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let prefs = BrowserPreferencesStore(
        fileURL: prefsDirectory.appending(path: "preferences.json"))
      let profile = UUID()
      prefs.setNativeVaultEnabled(true, for: profile)
      let backend = DelayedRefreshBackend()
      let controller = NativeBitwardenController(
        preferences: prefs, backend: backend, credentialStore: store)
      controller.selectProfile(profile)
      controller.email = "fixture@example.invalid"
      controller.masterPassword = "synthetic"
      controller.connect()
      for _ in 0..<500 where !(await backend.waiting()) { await Task.yield() }
      #expect(await backend.waiting())
      let account = backend.account
      if preferenceFailure {
        try FileManager.default.removeItem(at: prefsDirectory)
        try Data().write(to: prefsDirectory)
      } else {
        items.failDeletes()
      }
      controller.disconnect()
      try await backend.release()
      for _ in 0..<500 where controller.status != "Could not remove credentials securely." {
        await Task.yield()
      }
      #expect(controller.status == "Could not remove credentials securely.")
      #expect(prefs.nativeVaultPreferences(for: profile).accountID == account)
      #expect((items.onlyRecord() != nil) == !preferenceFailure)
      #expect(await backend.tokenValue() == nil)
    }
  #endif

  @Test func malformedIdentityAndFailedIntentNeverPublish() async throws {
    let foreign = try RefreshHarness()
    defer { foreign.cleanup() }
    let wrong = try foreign.token(account: UUID())
    var coordinator: NativeBitwardenRefreshCoordinator! = try foreign.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: wrong, refreshToken: "new", expiresIn: 3600))
    defer { coordinator = nil }
    do {
      _ = try await coordinator.ensureFresh()
      Issue.record("foreign account accepted")
    } catch {}
    #expect(foreign.published.isEmpty)
    guard case .record(let intent) = try foreign.read() else {
      Issue.record("missing intent")
      return
    }
    #expect(intent.state == .refreshInFlight)

    let denied = try RefreshHarness()
    defer { denied.cleanup() }
    var deniedCoordinator: NativeBitwardenRefreshCoordinator! = try denied.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try denied.token(), refreshToken: nil, expiresIn: 3600))
    defer { deniedCoordinator = nil }
    denied.storage.failWrites()
    do {
      _ = try await deniedCoordinator.ensureFresh()
      Issue.record("write failure accepted")
    } catch {}
    #expect(denied.responses == 0)
    #expect(denied.published.isEmpty)
  }

  @Test func foreignClientAndImpossibleExpiryRequireReauthentication() async throws {
    let wrongClient = try RefreshHarness()
    defer { wrongClient.cleanup() }
    var first: NativeBitwardenRefreshCoordinator! = try wrongClient.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try wrongClient.token(client: "other"), refreshToken: nil, expiresIn: 3600))
    defer { first = nil }
    do {
      _ = try await first.ensureFresh()
      Issue.record("foreign client accepted")
    } catch {}
    #expect(wrongClient.published.isEmpty)
    #expect(try wrongClient.lease.hasPendingRotation())

    let badExpiry = try RefreshHarness()
    defer { badExpiry.cleanup() }
    var second: NativeBitwardenRefreshCoordinator! = try badExpiry.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try badExpiry.token(), refreshToken: nil, expiresIn: 0))
    defer { second = nil }
    do {
      _ = try await second.ensureFresh()
      Issue.record("invalid expiry accepted")
    } catch {}
    #expect(badExpiry.published.isEmpty)
    #expect(try badExpiry.lease.hasPendingRotation())
  }

  @Test func markerFlushFailuresBlockPublicationAndPreserveRotationBoundary() async throws {
    let markCalls = Mutex(0)
    let failedMark = try RefreshHarness(flushFile: { fd in
      let call = markCalls.withLock { value in
        value += 1
        return value
      }
      return call == 1 ? -1 : Darwin.fsync(fd)
    })
    defer { failedMark.cleanup() }
    var first: NativeBitwardenRefreshCoordinator! = try failedMark.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try failedMark.token(), refreshToken: "rotated", expiresIn: 3600))
    defer { first = nil }
    do {
      _ = try await first.ensureFresh()
      Issue.record("failed intent flush accepted")
    } catch {}
    #expect(failedMark.responses == 0)
    #expect(failedMark.published.isEmpty)
    #expect(try failedMark.lease.hasPendingRotation())

    let clearCalls = Mutex(0)
    let failedClear = try RefreshHarness(flushFile: { fd in
      let call = clearCalls.withLock { value in
        value += 1
        return value
      }
      return call == 2 ? -1 : Darwin.fsync(fd)
    })
    defer { failedClear.cleanup() }
    var second: NativeBitwardenRefreshCoordinator! = try failedClear.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try failedClear.token(), refreshToken: "rotated", expiresIn: 3600))
    defer { second = nil }
    do {
      _ = try await second.ensureFresh()
      Issue.record("failed marker clear accepted")
    } catch {}
    #expect(failedClear.responses == 1)
    #expect(failedClear.published.isEmpty)
    guard case .record(let committed) = try failedClear.read() else {
      Issue.record("confirmed replacement missing")
      return
    }
    #expect(committed.revision == 2)
    #expect(committed.credential.refreshToken == "rotated")
  }

  @Test func ambiguousReplacementKeepsIndependentRestartFence() async throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    var coordinator: NativeBitwardenRefreshCoordinator! = try h.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try h.token(), refreshToken: "rotated", expiresIn: 3600))
    defer { coordinator = nil }
    h.storage.failAfterOneWrite()
    do {
      _ = try await coordinator.ensureFresh()
      Issue.record("ambiguous write accepted")
    } catch {}
    #expect(h.published.isEmpty)
    #expect(try h.lease.hasPendingRotation())
    guard case .record(let saved) = try h.read() else {
      Issue.record("missing record")
      return
    }
    #expect(saved.state == .ready)
    #expect(saved.revision == 2)
    #expect(throws: NativeBitwardenRefreshFailure.reauthenticationRequired) {
      try NativeBitwardenRefreshCoordinator(
        binding: h.binding, record: saved, store: h.store, lease: h.lease,
        transport: { _ in throw RefreshMemoryItems.TestError.failed },
        isOwner: { true }, publish: { _ in }, revoke: {})
    }
  }

  @Test func successfulWriteWithoutReadbackDoesNotPublish() async throws {
    let h = try RefreshHarness()
    defer { h.cleanup() }
    var coordinator: NativeBitwardenRefreshCoordinator! = try h.coordinator(
      result: NativeBitwardenRefreshResponse(
        accessToken: try h.token(), refreshToken: "rotated", expiresIn: 3600))
    defer { coordinator = nil }
    h.storage.dropAfterOneWrite()
    do {
      _ = try await coordinator.ensureFresh()
      Issue.record("unconfirmed write accepted")
    } catch {}
    #expect(h.published.isEmpty)
    #expect(try h.lease.hasPendingRotation())
    guard case .record(let saved) = try h.read() else {
      Issue.record("missing record")
      return
    }
    #expect(saved.state == .refreshInFlight)
  }

  @Test func typedUnauthorizedRetriesOnceAndOtherFailuresNeverRefresh() async throws {
    let h = try RefreshHarness(expiresIn: 3600)
    defer { h.cleanup() }
    let response = NativeBitwardenRefreshResponse(
      accessToken: try h.token(), refreshToken: "rotated", expiresIn: 3600)
    var coordinator: NativeBitwardenRefreshCoordinator! = try h.coordinator(result: response)
    defer { coordinator = nil }
    var attempts = 0
    let result = try await coordinator.performReadOnlySync {
      attempts += 1
      if attempts == 1 { throw NativeBitwardenBackendError.unauthorized }
      return "synced"
    }
    #expect(result == "synced")
    #expect(attempts == 2)
    #expect(h.responses == 1)
    guard case .record(let saved) = try h.read() else {
      Issue.record("missing record")
      return
    }
    #expect(saved.credential.refreshToken == "rotated")

    let denied = try RefreshHarness(expiresIn: 3600)
    defer { denied.cleanup() }
    var other: NativeBitwardenRefreshCoordinator! = try denied.coordinator(result: response)
    defer { other = nil }
    var deniedAttempts = 0
    do {
      _ = try await other.performReadOnlySync { () -> String in
        deniedAttempts += 1
        throw NativeBitwardenBackendError.syncFailed
      }
      Issue.record("failed sync accepted")
    } catch {}
    #expect(deniedAttempts == 1)
    #expect(denied.responses == 0)

    let repeated = try RefreshHarness(expiresIn: 3600)
    defer { repeated.cleanup() }
    let repeatResponse = NativeBitwardenRefreshResponse(
      accessToken: try repeated.token(), refreshToken: nil, expiresIn: 3600)
    var once: NativeBitwardenRefreshCoordinator! = try repeated.coordinator(result: repeatResponse)
    defer { once = nil }
    var repeatedAttempts = 0
    do {
      _ = try await once.performReadOnlySync { () -> String in
        repeatedAttempts += 1
        throw NativeBitwardenBackendError.unauthorized
      }
      Issue.record("second unauthorized accepted")
    } catch {}
    #expect(repeatedAttempts == 2)
    #expect(repeated.responses == 1)
  }
}

#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE && canImport(ArcusisBitwardenSDK)
  private struct NativeRefreshHostVector: Decodable {
    let endpoint: String
    let email: String
    let userID: String
    let currentPassword: String
  }

  final class NativeBitwardenRefreshHostFixtureTests: XCTestCase {
    func testFixtureGuardRejectsDesktopExecutable() {
      XCTAssertFalse(ArcusisBrowserMain.desktopEntryAllowed)
      let bundle = URL(fileURLWithPath: "/tmp/Synthetic.xctest")
      XCTAssertFalse(
        NativeBitwardenSDKBackend.isFixtureTestHost(
          executable: URL(fileURLWithPath: "/Applications/Browser.app/Contents/MacOS/Browser"),
          bundles: [bundle]))
      XCTAssertFalse(
        NativeBitwardenSDKBackend.isFixtureTestHost(
          executable: URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"),
          bundles: []))
      XCTAssertTrue(
        NativeBitwardenSDKBackend.isFixtureTestHost(
          executable: URL(fileURLWithPath: "/tmp/Synthetic.xctest/Contents/MacOS/Synthetic"),
          bundles: [bundle]))
    }

    func testFixtureGuardAcceptsCurrentTestHost() async {
      let backend = NativeBitwardenSDKBackend()
      let available = await backend.isAvailable
      XCTAssertTrue(available)
    }

    @MainActor func testOwnedHostRefreshAndLockedRestart() async throws {
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_REFRESH_HOST_FIXTURE"])
      let vector = try JSONDecoder().decode(
        NativeRefreshHostVector.self, from: try XCTUnwrap(Data(base64Encoded: encoded)))
      let endpoint = try XCTUnwrap(URL(string: vector.endpoint))
      guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path.isEmpty, endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else {
        XCTFail("Invalid owned endpoint")
        return
      }
      let expectedAccount = try XCTUnwrap(UUID(uuidString: vector.userID))
      let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let preferencesFile = directory.appending(path: "preferences.json")
      let storage = RefreshMemoryItems()
      let credentials = PasswordCredentialStore(
        service: "refresh-host-fixture", storage: storage, sessionLockDirectory: directory,
        usesSessionLocks: true)
      let profile = UUID()
      let prefs = BrowserPreferencesStore(fileURL: preferencesFile)
      prefs.setNativeVaultServer(
        BitwardenServerConfiguration(region: .custom, customBaseURL: "https://fixture.example"),
        for: profile)
      prefs.setNativeVaultEnabled(true, for: profile)

      func cycle(restored: Bool, preferences: BrowserPreferencesStore) async throws {
        let backend = NativeBitwardenSDKBackend { provider, settings in
          let local = ClientSettings(
            identityUrl: vector.endpoint + "/identity", apiUrl: vector.endpoint + "/api",
            userAgent: settings.userAgent, deviceType: .sdk,
            deviceIdentifier: settings.deviceIdentifier,
            bitwardenClientVersion: settings.bitwardenClientVersion,
            bitwardenPackageType: settings.bitwardenPackageType)
          return Client(
            tokenProvider: provider, settings: local,
            managedSettings: ManagedSettingsBindingClient())
        }
        let available = await backend.isAvailable
        XCTAssertTrue(available)
        let controller = NativeBitwardenController(
          preferences: preferences, backend: backend, credentialStore: credentials)
        controller.selectProfile(profile)
        XCTAssertFalse(controller.hasConnectedSession)
        controller.email = vector.email
        controller.masterPassword = vector.currentPassword
        controller.connect()
        for _ in 0..<400 {
          if controller.syncStatus.hasPrefix("Synced")
            || controller.syncStatus.hasPrefix("Sync failed")
          {
            break
          }
          if !controller.isLoading && controller.status.contains("failed") { break }
          try await Task.sleep(for: .milliseconds(25))
        }
        if restored {
          XCTAssertTrue(controller.syncStatus.hasPrefix("Sync failed"), "403 did not fail closed")
        } else {
          XCTAssertTrue(controller.syncStatus.hasPrefix("Synced"), "Host sync did not complete")
        }
        let stored = preferences.nativeVaultPreferences(for: profile)
        XCTAssertEqual(stored.accountID, expectedAccount)
        let raw = try XCTUnwrap(storage.onlyRecord())
        let endpoints = try stored.server.endpoints()
        let binding = PasswordAuthenticationBinding(
          profileID: profile, vaultID: stored.vaultID, accountID: expectedAccount,
          authority: endpoints.credentialAuthority)
        let record = try PasswordSessionRecoveryRecord.decode(
          raw, binding: binding, identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
          serviceID: endpoints.stableServiceID, deviceID: stored.deviceID, clientID: "desktop",
          sdkRevision: NativeBitwardenController.recoverySDKRevision)
        XCTAssertEqual(record.state, .ready)
        XCTAssertEqual(record.revision, 2)
        XCTAssertTrue(record.credential.refreshToken == "synthetic-rotated-two")
        if restored { XCTAssertTrue(controller.hasConnectedSession) }
        controller.lock()
        for _ in 0..<200 {
          if controller.status == "Locked" { break }
          try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(controller.status, "Locked")
      }
      try await cycle(restored: false, preferences: prefs)
      let reloaded = BrowserPreferencesStore(fileURL: preferencesFile)
      XCTAssertEqual(reloaded.nativeVaultPreferences(for: profile).accountID, expectedAccount)
      try await cycle(restored: true, preferences: reloaded)
    }
  }
#endif
