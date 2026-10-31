import BrowserCore
import Foundation
import Observation
import Synchronization
import Testing

@testable import ArcusisBrowser
@testable import BrowserCore

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif

private final class MemoryCredentialItems: PasswordCredentialItemStorage, Sendable {
  private let values = Mutex<[String: Data]>([:])
  private let failAfterWrite = Mutex(false)
  private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }
  func read(service: String, account: String) throws -> Data? {
    values.withLock { $0[key(service, account)] }
  }
  func write(_ data: Data, service: String, account: String) throws {
    values.withLock { $0[key(service, account)] = data }
    if failAfterWrite.withLock({ $0 }) { throw MemoryCredentialItemsError.writeFailed }
  }
  func delete(service: String, account: String) throws {
    _ = values.withLock { $0.removeValue(forKey: key(service, account)) }
  }
  var count: Int { values.withLock { $0.count } }
  func failWritesAfterMutation(_ value: Bool) { failAfterWrite.withLock { $0 = value } }
}

private enum MemoryCredentialItemsError: Error { case writeFailed }

private actor ControlledBitwardenBackend: NativeBitwardenBackend {
  enum Mode { case waiting, failInitialization, succeed }
  enum CryptoOutcome: Sendable { case deferred, fail, succeed }
  struct Plan: Sendable {
    let candidateID: UUID
    let accountID: UUID
    let establishedID: UUID?
    let establishedAccountID: UUID?
    let token: String
    let loginDeferred: Bool
    let cryptoOutcome: CryptoOutcome
    let challengeProviders: [NativeBitwardenMFAProvider]?
    let snapshot: NativeBitwardenVaultSnapshot
    let syncDeferred: Bool
    let syncFails: Bool

    init(
      candidateID: UUID = UUID(), accountID: UUID, token: String,
      establishedID: UUID? = nil, establishedAccountID: UUID? = nil,
      loginDeferred: Bool = false, cryptoOutcome: CryptoOutcome = .succeed,
      challengeProviders: [NativeBitwardenMFAProvider]? = nil,
      snapshot: NativeBitwardenVaultSnapshot = .empty, syncDeferred: Bool = false,
      syncFails: Bool = false
    ) {
      self.candidateID = candidateID
      self.accountID = accountID
      self.establishedID = establishedID
      self.establishedAccountID = establishedAccountID
      self.token = token
      self.loginDeferred = loginDeferred
      self.cryptoOutcome = cryptoOutcome
      self.challengeProviders = challengeProviders
      self.snapshot = snapshot
      self.syncDeferred = syncDeferred
      self.syncFails = syncFails
    }
  }

  private(set) var discarded: [UUID] = []
  private(set) var locked: [UUID] = []
  private(set) var initialized: [UUID] = []
  private var loginContinuations: [UUID: CheckedContinuation<NativeBitwardenLoginResult, Never>] =
    [:]
  private var cryptoContinuations:
    [UUID: CheckedContinuation<NativeBitwardenEstablishedSession, Error>] = [:]
  private var syncContinuations: [UUID: CheckedContinuation<NativeBitwardenVaultSnapshot, Error>] =
    [:]
  private var syncStartedIDs: Set<UUID> = []
  private var loginStartedIDs: Set<UUID> = []
  private var tokenProviders: [UUID: NativeBitwardenTokenProvider] = [:]
  private var planIndex = 0
  private let plans: [Plan]
  let candidateID: UUID
  let accountID: UUID

  init(mode: Mode = .waiting) {
    let accountID = UUID()
    let candidateID = UUID()
    let outcome: CryptoOutcome = mode == .failInitialization ? .fail : .succeed
    plans = [
      Plan(
        candidateID: candidateID, accountID: accountID, token: "candidate-token",
        loginDeferred: mode == .waiting, cryptoOutcome: outcome)
    ]
    self.candidateID = candidateID
    self.accountID = accountID
  }

  init(plans: [Plan]) {
    self.plans = plans
    candidateID = plans[0].candidateID
    accountID = plans[0].accountID
  }

  var isAvailable: Bool { true }

  func login(
    server: BitwardenServerConfiguration, email: String, password: String, deviceID: UUID,
    secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult {
    let plan = plans[min(planIndex, plans.count - 1)]
    planIndex += 1
    loginStartedIDs.insert(plan.candidateID)
    if let providers = plan.challengeProviders { return .challenge(UUID(), providers) }
    if plan.loginDeferred {
      return await withCheckedContinuation { loginContinuations[plan.candidateID] = $0 }
    }
    return .authenticated(.init(id: plan.candidateID, accountID: plan.accountID))
  }

  func resolveLogin() {
    guard let (id, continuation) = loginContinuations.first,
      let plan = plans.first(where: { $0.candidateID == id })
    else { return }
    continuation.resume(returning: .authenticated(.init(id: id, accountID: plan.accountID)))
    loginContinuations.removeValue(forKey: id)
  }

  func initializeCrypto(candidateID: UUID, password: String) async throws
    -> NativeBitwardenEstablishedSession
  {
    initialized.append(candidateID)
    guard let plan = plans.first(where: { $0.candidateID == candidateID }) else {
      throw NativeBitwardenBackendError.candidateUnavailable
    }
    switch plan.cryptoOutcome {
    case .deferred:
      return try await withCheckedThrowingContinuation { cryptoContinuations[candidateID] = $0 }
    case .fail:
      throw NativeBitwardenBackendError.unsupportedCryptoSetup
    case .succeed:
      return makeSession(plan)
    }
  }

  func resolveCrypto(_ candidateID: UUID) {
    guard let continuation = cryptoContinuations.removeValue(forKey: candidateID),
      let plan = plans.first(where: { $0.candidateID == candidateID })
    else { return }
    continuation.resume(returning: makeSession(plan))
  }

  func failCrypto(_ candidateID: UUID) {
    cryptoContinuations.removeValue(forKey: candidateID)?.resume(
      throwing: NativeBitwardenBackendError.unsupportedCryptoSetup)
  }

  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot {
    syncStartedIDs.insert(sessionID)
    guard let plan = plans.first(where: { $0.candidateID == sessionID }) else {
      throw NativeBitwardenBackendError.candidateUnavailable
    }
    if plan.syncFails { throw NativeBitwardenBackendError.staleSession }
    if plan.syncDeferred {
      return try await withCheckedThrowingContinuation { syncContinuations[sessionID] = $0 }
    }
    return plan.snapshot
  }

  func resolveSync(_ sessionID: UUID) {
    guard let continuation = syncContinuations.removeValue(forKey: sessionID),
      let plan = plans.first(where: { $0.candidateID == sessionID })
    else { return }
    continuation.resume(returning: plan.snapshot)
  }

  func didStartSync(_ id: UUID) -> Bool { syncStartedIDs.contains(id) }

  private func makeSession(_ plan: Plan) -> NativeBitwardenEstablishedSession {
    let provider = NativeBitwardenTokenProvider()
    tokenProviders[plan.candidateID] = provider
    return NativeBitwardenEstablishedSession(
      id: plan.establishedID ?? plan.candidateID,
      accountID: plan.establishedAccountID ?? plan.accountID,
      credential: PasswordCredential(accessToken: plan.token, refreshToken: "refresh-token"),
      tokenProvider: provider)
  }

  func lock(sessionID: UUID) async -> Bool {
    locked.append(sessionID)
    return true
  }
  func discard(sessionID: UUID) async {
    discarded.append(sessionID)
    tokenProviders[sessionID]?.clear()
  }
  func didDiscard(_ id: UUID) -> Bool { discarded.contains(id) }
  func discardCount(_ id: UUID) -> Int { discarded.filter { $0 == id }.count }
  func didLock(_ id: UUID) -> Bool { locked.contains(id) }
  func didInitialize(_ id: UUID) -> Bool { initialized.contains(id) }
  func hasStartedLogin(_ id: UUID? = nil) -> Bool {
    id.map { loginStartedIDs.contains($0) } ?? !loginStartedIDs.isEmpty
  }
  func hasStartedCrypto(_ id: UUID) -> Bool { initialized.contains(id) }
  func hasProducedSession(_ id: UUID) -> Bool { tokenProviders[id] != nil }
  func token(for id: UUID) async -> String? { await tokenProviders[id]?.getAccessToken() }
}

@Suite @MainActor
struct NativeBitwardenControllerTests {
  #if canImport(ArcusisBitwardenSDK)
    @Test func acceptedSDKClientExecutesTypedCryptoClearAndRejectsUnknownHandle() async {
      let bridge = NativeBitwardenStateBridge()
      NativeBitwardenLogging.bootstrap()
      let client = Client(
        tokenProvider: NativeBitwardenTokenProvider(),
        settings: ClientSettings(
          identityUrl: "https://identity.example.test", apiUrl: "https://api.example.test",
          userAgent: "Shaar development smoke", deviceType: .sdk,
          deviceIdentifier: UUID().uuidString, bitwardenClientVersion: "0.1.0",
          bitwardenPackageType: "desktop"),
        managedSettings: ManagedSettingsBindingClient())
      client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
      client.crypto().clearUserCryptoKeys()
      #expect(!(await bridge.hasTransientKeyState()))

      let backend = NativeBitwardenSDKBackend()
      #expect(!(await backend.lock(sessionID: UUID())))
      await #expect(throws: NativeBitwardenBackendError.candidateUnavailable) {
        try await backend.syncVault(sessionID: UUID())
      }
    }
  #endif

  @Test func accessTokenIdentityRequiresBoundedUUIDSubject() throws {
    let expected = UUID()
    let payload = Data("{\"sub\":\"\(expected.uuidString)\"}".utf8).base64URLEncodedString()
    #expect(try NativeBitwardenAccessTokenIdentity.userID(from: "e30.\(payload).sig") == expected)
    #expect(throws: NativeBitwardenBackendError.invalidAccessToken) {
      try NativeBitwardenAccessTokenIdentity.userID(
        from: "e30.\(Data("{}".utf8).base64URLEncodedString()).sig")
    }
    #expect(throws: NativeBitwardenBackendError.invalidAccessToken) {
      try NativeBitwardenAccessTokenIdentity.userID(from: String(repeating: "x", count: 32_769))
    }
  }

  @Test func successfulAuthenticationPublishesActualTypedVaultSnapshot() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let cipherID = UUID()
    let snapshot = try! NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: cipherID, name: "Work", username: "alice", uris: ["https://example.test"],
        isLogin: true, isOrganization: false)
    ])
    let plan = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "vault-token", snapshot: snapshot)
    let backend = ControlledBitwardenBackend(plans: [plan])
    let controller = makeTestController(preferences: preferences, backend: backend)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.syncStatus == "Synced 1 logins" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status == "Connected and unlocked")
    #expect(controller.vaultSnapshot.logins.map(\.id) == [cipherID])
    #expect(controller.vaultSnapshot.logins.first?.username == "alice")
    #expect(controller.vaultSnapshot.logins.first?.uris.map(\.uri) == ["https://example.test"])
    #expect(await backend.didStartSync(plan.candidateID))
  }

  @Test func syncFailureDoesNotPublishSnapshotAndPreservesAuthenticationStatus() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let plan = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "vault-token", syncFails: true)
    let controller = makeTestController(
      preferences: preferences, backend: ControlledBitwardenBackend(plans: [plan]))
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.syncStatus.hasPrefix("Sync failed") { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status == "Connected and unlocked")
    #expect(controller.vaultSnapshot == .empty)
    #expect(controller.syncStatus == "Sync failed. Vault metadata unavailable.")
  }

  @Test func lockedProfileRejectsDeferredSyncAndClearsMetadataBeforeAwait() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let id = UUID()
    let snapshot = try! NativeBitwardenVaultSnapshot.make(from: [
      .init(id: id, name: "Login", username: nil, uris: [], isLogin: true, isOrganization: false)
    ])
    let plan = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "vault-token", snapshot: snapshot, syncDeferred: true)
    let backend = ControlledBitwardenBackend(plans: [plan])
    let controller = makeTestController(preferences: preferences, backend: backend)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.didStartSync(plan.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.lock()
    #expect(controller.vaultSnapshot == .empty)
    #expect(controller.syncStatus == "Locked")
    await backend.resolveSync(plan.candidateID)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(controller.vaultSnapshot == .empty)
    #expect(controller.syncStatus == "Locked")
  }

  @Test func closingSettingsKeepsCommittedSessionAndPublishesObservedSyncResult() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let cipherID = UUID()
    let snapshot = try! NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: cipherID, name: "Login", username: "user", uris: [], isLogin: true,
        isOrganization: false)
    ])
    let plan = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "vault-token", snapshot: snapshot, syncDeferred: true)
    let backend = ControlledBitwardenBackend(plans: [plan])
    let controller = makeTestController(preferences: preferences, backend: backend)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.didStartSync(plan.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let didNotify = Mutex(false)
    withObservationTracking {
      _ = controller.vaultSnapshot
    } onChange: {
      didNotify.withLock { $0 = true }
    }
    controller.closeSettings()
    #expect(controller.hasConnectedSession)
    #expect(controller.masterPassword.isEmpty)
    await backend.resolveSync(plan.candidateID)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(didNotify.withLock { $0 })
    #expect(controller.vaultSnapshot.logins.map(\.id) == [cipherID])
    #expect(controller.syncStatus == "Synced 1 logins")
    #expect(controller.hasConnectedSession)
  }

  @Test func disconnectDisableAndRebindRejectDeferredSyncResults() async {
    for invalidation in ["disconnect", "disable", "rebind"] {
      let preferences = BrowserPreferencesStore()
      let profile = UUID()
      let cipherID = UUID()
      let snapshot = try! NativeBitwardenVaultSnapshot.make(from: [
        .init(
          id: cipherID, name: "Stale", username: nil, uris: [], isLogin: true,
          isOrganization: false)
      ])
      let plan = ControlledBitwardenBackend.Plan(
        accountID: UUID(), token: "vault-token", snapshot: snapshot, syncDeferred: true)
      let backend = ControlledBitwardenBackend(plans: [plan])
      let controller = makeTestController(preferences: preferences, backend: backend)
      controller.selectProfile(profile)
      controller.setEnabled(true)
      controller.email = "person@example.test"
      controller.masterPassword = "secret"
      controller.connect()
      for _ in 0..<50 {
        if await backend.didStartSync(plan.candidateID) { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
      switch invalidation {
      case "disconnect": controller.disconnect()
      case "disable": controller.setEnabled(false)
      default: controller.setServer(BitwardenServerConfiguration(region: .eu))
      }
      #expect(controller.vaultSnapshot == .empty)
      await backend.resolveSync(plan.candidateID)
      try? await Task.sleep(for: .milliseconds(30))
      #expect(controller.vaultSnapshot == .empty)
    }
  }

  @Test func reconnectAndOtherProfileKeepVaultSnapshotsIsolated() async {
    let preferences = BrowserPreferencesStore()
    let firstProfile = UUID()
    let secondProfile = UUID()
    let firstID = UUID()
    let secondID = UUID()
    let firstSnapshot = try! NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: firstID, name: "First", username: nil, uris: [], isLogin: true, isOrganization: false)
    ])
    let secondSnapshot = try! NativeBitwardenVaultSnapshot.make(from: [
      .init(
        id: secondID, name: "Second", username: nil, uris: [], isLogin: true, isOrganization: false)
    ])
    let first = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "first", snapshot: firstSnapshot, syncDeferred: true)
    let replacement = ControlledBitwardenBackend.Plan(
      accountID: first.accountID, token: "replacement", snapshot: .empty)
    let second = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "second", snapshot: secondSnapshot)
    let backend = ControlledBitwardenBackend(plans: [first, replacement, second])
    let controller = makeTestController(preferences: preferences, backend: backend)

    controller.selectProfile(firstProfile)
    controller.setEnabled(true)
    controller.email = "first@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.didStartSync(first.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.vaultSnapshot == .empty)

    controller.email = "first@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.syncStatus == "Synced 0 logins" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    await backend.resolveSync(first.candidateID)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(controller.vaultSnapshot == .empty)

    controller.selectProfile(secondProfile)
    controller.setEnabled(true)
    controller.email = "second@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.syncStatus == "Synced 1 logins" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.vaultSnapshot.logins.map(\.id) == [secondID])
    controller.selectProfile(firstProfile)
    #expect(controller.vaultSnapshot == .empty)
    #expect(controller.syncStatus == "Synced 0 logins")
  }

  @Test func loginMetadataUsesRegisteredDesktopClientTypeAndArcusisIdentity() {
    #expect(NativeBitwardenLoginRequestMetadata.clientID == "desktop")
    #expect(NativeBitwardenLoginRequestMetadata.userAgent == "Shaar")
    #expect(NativeBitwardenLoginRequestMetadata.deviceName == "Shaar")
  }

  @Test func profileSessionsRemainIndependentAndSettingsCloseClearsSecrets() async {
    let preferences = BrowserPreferencesStore()
    let first = UUID()
    let second = UUID()
    let backend = ControlledBitwardenBackend(mode: .waiting)
    let controller = makeTestController(preferences: preferences, backend: backend)
    controller.selectProfile(first)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedLogin() { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.selectProfile(second)
    #expect(controller.masterPassword.isEmpty)
    #expect(!controller.hasConnectedSession)
    #expect(!controller.isLoading)
    controller.selectProfile(first)
    #expect(controller.isEnabled)
    #expect(controller.isLoading)
    controller.masterPassword = "secret-again"
    controller.mfaToken = "654321"
    controller.closeSettings()
    #expect(controller.masterPassword.isEmpty)
    #expect(controller.mfaToken.isEmpty)
    await backend.resolveLogin()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!controller.hasConnectedSession)
    let candidateID = backend.candidateID
    #expect(!(await backend.didInitialize(candidateID)))
    #expect(await backend.didDiscard(candidateID))
  }

  @Test func failedCryptoInitializationNeverPublishesCredentials() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let backend = ControlledBitwardenBackend(mode: .failInitialization)
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "native-vault-test", storage: items)
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.status.contains("failed") { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status.contains("failed"))
    #expect(items.count == 0)
    #expect(preferences.nativeVaultPreferences(for: profile).accountID == nil)
  }

  @Test func disableAndServerRebindRejectLateLoginResults() async {
    for rebind in [false, true] {
      let preferences = BrowserPreferencesStore()
      let profile = UUID()
      let backend = ControlledBitwardenBackend(mode: .waiting)
      let items = MemoryCredentialItems()
      let credentials = PasswordCredentialStore(service: "stale-vault-test", storage: items)
      let controller = NativeBitwardenController(
        preferences: preferences, backend: backend, credentialStore: credentials)
      controller.selectProfile(profile)
      controller.setEnabled(true)
      controller.email = "person@example.test"
      controller.masterPassword = "secret"
      controller.connect()
      for _ in 0..<50 {
        if await backend.hasStartedLogin() { break }
        try? await Task.sleep(for: .milliseconds(10))
      }

      if rebind {
        controller.setServer(BitwardenServerConfiguration(region: .eu))
      } else {
        controller.setEnabled(false)
      }
      await backend.resolveLogin()
      let candidateID = backend.candidateID
      for _ in 0..<50 {
        if await backend.didDiscard(candidateID) { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
      #expect(items.count == 0)
      #expect(!controller.hasConnectedSession)
      #expect(!(await backend.didInitialize(candidateID)))
    }
  }

  @Test func lockRetainsCredentialUntilExactDisconnect() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let backend = ControlledBitwardenBackend(mode: .succeed)
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "disconnect-vault-test", storage: items)
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.hasConnectedSession { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.hasConnectedSession)
    #expect(items.count == 1)
    controller.lock()
    for _ in 0..<50 {
      if controller.status == "Locked" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.status == "Locked")
    #expect(items.count == 1)
    controller.disconnect()
    #expect(items.count == 0)
    #expect(!controller.hasConnectedSession)
  }

  @Test func staleCryptoSuccessCannotClearPublishedSessionOrNewPendingAttempt() async throws {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let account = UUID()
    let old = ControlledBitwardenBackend.Plan(
      accountID: account, token: "old-token", cryptoOutcome: .deferred)
    let current = ControlledBitwardenBackend.Plan(accountID: account, token: "current-token")
    let pending = ControlledBitwardenBackend.Plan(
      accountID: account, token: "pending-token", cryptoOutcome: .deferred)
    let backend = ControlledBitwardenBackend(plans: [old, current, pending])
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "overlap-vault-test", storage: items)
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedCrypto(old.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    controller.connect()
    for _ in 0..<50 {
      if controller.status == "Connected and unlocked" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedCrypto(pending.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    await backend.resolveCrypto(old.candidateID)
    for _ in 0..<50 {
      if await backend.didDiscard(old.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let binding = try passwordBinding(preferences, profile: profile, account: account)
    #expect(try credentials.read(for: binding)?.accessToken == "current-token")
    #expect(await backend.token(for: current.candidateID) == "current-token")
    #expect(!(await backend.didDiscard(current.candidateID)))
    #expect(controller.hasConnectedSession)
    #expect(controller.isLoading)
    #expect(controller.status == "Connecting…")

    await backend.resolveCrypto(pending.candidateID)
  }

  @Test func staleCryptoFailureAfterNewSuccessPreservesCredentialAndSession() async throws {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let account = UUID()
    let old = ControlledBitwardenBackend.Plan(
      accountID: account, token: "old-token", cryptoOutcome: .deferred)
    let current = ControlledBitwardenBackend.Plan(accountID: account, token: "current-token")
    let backend = ControlledBitwardenBackend(plans: [old, current])
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "stale-failure-test", storage: items)
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedCrypto(old.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.connect()
    for _ in 0..<50 {
      if controller.status == "Connected and unlocked" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    await backend.failCrypto(old.candidateID)
    try? await Task.sleep(for: .milliseconds(30))

    let binding = try passwordBinding(preferences, profile: profile, account: account)
    #expect(try credentials.read(for: binding)?.accessToken == "current-token")
    #expect(await backend.token(for: current.candidateID) == "current-token")
    #expect(!(await backend.didDiscard(current.candidateID)))
    #expect(controller.hasConnectedSession)
    #expect(controller.status == "Connected and unlocked")
  }

  @Test func staleCryptoFailureAfterProfileSwitchCannotClearSelectedProfileForm() async {
    let preferences = BrowserPreferencesStore()
    let account = UUID()
    let old = ControlledBitwardenBackend.Plan(
      accountID: account, token: "old-token", cryptoOutcome: .deferred)
    let current = ControlledBitwardenBackend.Plan(accountID: account, token: "current-token")
    let backend = ControlledBitwardenBackend(plans: [old, current])
    let controller = makeTestController(preferences: preferences, backend: backend)
    let first = UUID()
    let second = UUID()
    controller.selectProfile(first)
    controller.setEnabled(true)
    controller.email = "first@example.test"
    controller.masterPassword = "first-secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedCrypto(old.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    controller.selectProfile(second)
    controller.setEnabled(true)
    controller.email = "second@example.test"
    controller.masterPassword = "second-secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.status == "Connected and unlocked" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.email = "keep-this-edit@example.test"
    await backend.failCrypto(old.candidateID)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(controller.email == "keep-this-edit@example.test")
    #expect(controller.status == "Connected and unlocked")
    #expect(controller.hasConnectedSession)
    #expect(!controller.isLoading)
  }

  @Test func accountSwitchPublishesOnlyUnderAuthenticatedBindingAndRetiresPriorSession()
    async throws
  {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let first = ControlledBitwardenBackend.Plan(accountID: UUID(), token: "first-token")
    let second = ControlledBitwardenBackend.Plan(accountID: UUID(), token: "second-token")
    let backend = ControlledBitwardenBackend(plans: [first, second])
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "switch-vault-test", storage: items)
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "first@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.hasConnectedSession { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let firstBinding = try passwordBinding(preferences, profile: profile, account: first.accountID)
    #expect(try credentials.read(for: firstBinding)?.accessToken == "first-token")
    let originalPreferences = preferences.nativeVaultPreferences(for: profile)
    controller.email = "second@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.status == "Connected and unlocked", await backend.didDiscard(first.candidateID)
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let secondBinding = try passwordBinding(
      preferences, profile: profile, account: second.accountID)
    let updated = preferences.nativeVaultPreferences(for: profile)
    #expect(updated.accountID == second.accountID)
    #expect(updated.vaultID == originalPreferences.vaultID)
    #expect(updated.server == originalPreferences.server)
    #expect(try credentials.read(for: firstBinding) == nil)
    #expect(try credentials.read(for: secondBinding)?.accessToken == "second-token")
    #expect(items.count == 1)
    #expect(await backend.token(for: first.candidateID) == nil)
    #expect(await backend.didDiscard(first.candidateID))
    #expect(await backend.token(for: second.candidateID) == "second-token")
    #expect(controller.hasConnectedSession)
  }

  @Test func mismatchedInitializedIdentityNeverPublishesCredentialsOrPreferences() async throws {
    for mismatchID in [false, true] {
      let preferences = BrowserPreferencesStore()
      let profile = UUID()
      let account = UUID()
      preferences.setNativeVaultAccountID(account, for: profile)
      let plan = ControlledBitwardenBackend.Plan(
        accountID: account, token: "bad-token",
        establishedID: mismatchID ? UUID() : nil,
        establishedAccountID: mismatchID ? nil : UUID())
      let backend = ControlledBitwardenBackend(plans: [plan])
      let items = MemoryCredentialItems()
      let credentials = PasswordCredentialStore(service: "mismatch-vault-test", storage: items)
      let controller = NativeBitwardenController(
        preferences: preferences, backend: backend, credentialStore: credentials)
      controller.selectProfile(profile)
      controller.setEnabled(true)
      controller.email = "person@example.test"
      controller.masterPassword = "secret"
      controller.connect()
      for _ in 0..<50 {
        if controller.status.contains("initialization failed") { break }
        try? await Task.sleep(for: .milliseconds(10))
      }

      #expect(controller.status.contains("initialization failed"))
      #expect(preferences.nativeVaultPreferences(for: profile).accountID == account)
      #expect(items.count == 0)
      #expect(!controller.hasConnectedSession)
      #expect(await backend.didDiscard(plan.candidateID))
      #expect(await backend.token(for: plan.candidateID) == nil)
      if let otherID = plan.establishedID { #expect(!(await backend.didDiscard(otherID))) }
    }
  }

  @Test func lateMismatchedSessionCannotEraseNewerAccountSession() async throws {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let current = ControlledBitwardenBackend.Plan(accountID: UUID(), token: "current-token")
    let old = ControlledBitwardenBackend.Plan(
      accountID: UUID(), token: "old-token", establishedID: current.candidateID,
      establishedAccountID: current.accountID, cryptoOutcome: .deferred)
    let backend = ControlledBitwardenBackend(plans: [old, current])
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "late-mismatch-test", storage: items)
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "old@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedCrypto(old.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.email = "current@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.hasConnectedSession { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    await backend.resolveCrypto(old.candidateID)
    for _ in 0..<50 {
      if await backend.hasProducedSession(old.candidateID),
        await backend.token(for: old.candidateID) == nil,
        await backend.discardCount(old.candidateID) >= 2
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let binding = try passwordBinding(preferences, profile: profile, account: current.accountID)
    #expect(preferences.nativeVaultPreferences(for: profile).accountID == current.accountID)
    #expect(try credentials.read(for: binding)?.accessToken == "current-token")
    #expect(items.count == 1)
    #expect(await backend.discardCount(old.candidateID) >= 2)
    #expect(await backend.token(for: current.candidateID) == "current-token")
    #expect(!(await backend.didDiscard(current.candidateID)))
    #expect(controller.status == "Connected and unlocked")
    #expect(controller.hasConnectedSession)
  }

  @Test func successfulSameBindingReconnectRetiresExactPriorSession() async throws {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let account = UUID()
    let first = ControlledBitwardenBackend.Plan(accountID: account, token: "first-token")
    let second = ControlledBitwardenBackend.Plan(accountID: account, token: "second-token")
    let backend = ControlledBitwardenBackend(plans: [first, second])
    let credentials = PasswordCredentialStore(
      service: "reconnect-vault-test", storage: MemoryCredentialItems())
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.status == "Connected and unlocked" { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.didDiscard(first.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let binding = try passwordBinding(preferences, profile: profile, account: account)
    #expect(await backend.didDiscard(first.candidateID))
    #expect(await backend.token(for: first.candidateID) == nil)
    #expect(await backend.token(for: second.candidateID) == "second-token")
    #expect(try credentials.read(for: binding)?.accessToken == "second-token")
    #expect(controller.hasConnectedSession)
  }

  @Test func lockInvalidatesPendingCryptoAndKeepsLockedSession() async throws {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let account = UUID()
    let first = ControlledBitwardenBackend.Plan(accountID: account, token: "first-token")
    let pending = ControlledBitwardenBackend.Plan(
      accountID: account, token: "pending-token", cryptoOutcome: .deferred)
    let backend = ControlledBitwardenBackend(plans: [first, pending])
    let credentials = PasswordCredentialStore(
      service: "lock-pending-test", storage: MemoryCredentialItems())
    let controller = NativeBitwardenController(
      preferences: preferences, backend: backend, credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.hasConnectedSession { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if await backend.hasStartedCrypto(pending.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    controller.lock()
    for _ in 0..<50 {
      if await backend.didLock(first.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    await backend.resolveCrypto(pending.candidateID)
    for _ in 0..<50 {
      if await backend.didDiscard(pending.candidateID) { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let binding = try passwordBinding(preferences, profile: profile, account: account)
    #expect(await backend.didLock(first.candidateID))
    #expect(await backend.didDiscard(pending.candidateID))
    #expect(await backend.token(for: pending.candidateID) == nil)
    #expect(try credentials.read(for: binding)?.accessToken == "first-token")
    #expect(controller.hasConnectedSession)
    #expect(controller.status == "Locked")
  }

  @Test func failedSecureWriteRestoresPreexistingCredential() async throws {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let account = UUID()
    preferences.setNativeVaultAccountID(account, for: profile)
    let value = preferences.nativeVaultPreferences(for: profile)
    let binding = try passwordBinding(preferences, profile: profile, account: account)
    let items = MemoryCredentialItems()
    let credentials = PasswordCredentialStore(service: "failed-write-test", storage: items)
    let existing = PasswordCredential(accessToken: "existing-token", refreshToken: nil)
    try credentials.write(existing, for: binding)
    items.failWritesAfterMutation(true)
    let plan = ControlledBitwardenBackend.Plan(accountID: account, token: "attempted-token")
    let controller = NativeBitwardenController(
      preferences: preferences, backend: ControlledBitwardenBackend(plans: [plan]),
      credentialStore: credentials)
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.status == "Could not save credentials securely." { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(value.accountID == account)
    #expect(try credentials.read(for: binding) == existing)
    #expect(!controller.hasConnectedSession)
    #expect(controller.status == "Could not save credentials securely.")
  }

  @Test func unsupportedOnlyMFAChallengeGetsExplicitState() async {
    let preferences = BrowserPreferencesStore()
    let profile = UUID()
    let account = UUID()
    let plan = ControlledBitwardenBackend.Plan(
      accountID: account, token: "unused", challengeProviders: [])
    let controller = makeTestController(
      preferences: preferences, backend: ControlledBitwardenBackend(plans: [plan]))
    controller.selectProfile(profile)
    controller.setEnabled(true)
    controller.email = "person@example.test"
    controller.masterPassword = "secret"
    controller.connect()
    for _ in 0..<50 {
      if controller.status.contains("does not support") { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(controller.status.contains("does not support"))
    #expect(controller.supportedMFAProviders.isEmpty)
    #expect(!controller.isLoading)
    #expect(NativeBitwardenMFAProvider.allCases == [.authenticator, .email, .yubikey])
  }
}

@MainActor
private func makeTestController(
  preferences: BrowserPreferencesStore, backend: any NativeBitwardenBackend
) -> NativeBitwardenController {
  NativeBitwardenController(
    preferences: preferences, backend: backend,
    credentialStore: PasswordCredentialStore(
      service: "native-bitwarden-controller-tests", storage: MemoryCredentialItems()))
}

@MainActor
private func passwordBinding(
  _ preferences: BrowserPreferencesStore, profile: UUID, account: UUID
) throws -> PasswordAuthenticationBinding {
  let value = preferences.nativeVaultPreferences(for: profile)
  return PasswordAuthenticationBinding(
    profileID: profile, vaultID: value.vaultID, accountID: account,
    authority: try value.server.endpoints().credentialAuthority)
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
