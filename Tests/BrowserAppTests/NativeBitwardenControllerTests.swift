import BrowserCore
import Foundation
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
    let token: String
    let loginDeferred: Bool
    let cryptoOutcome: CryptoOutcome
    let challengeProviders: [NativeBitwardenMFAProvider]?

    init(
      candidateID: UUID = UUID(), accountID: UUID, token: String,
      loginDeferred: Bool = false, cryptoOutcome: CryptoOutcome = .succeed,
      challengeProviders: [NativeBitwardenMFAProvider]? = nil
    ) {
      self.candidateID = candidateID
      self.accountID = accountID
      self.token = token
      self.loginDeferred = loginDeferred
      self.cryptoOutcome = cryptoOutcome
      self.challengeProviders = challengeProviders
    }
  }

  private(set) var discarded: [UUID] = []
  private(set) var locked: [UUID] = []
  private(set) var initialized: [UUID] = []
  private var loginContinuations: [UUID: CheckedContinuation<NativeBitwardenLoginResult, Never>] =
    [:]
  private var cryptoContinuations:
    [UUID: CheckedContinuation<NativeBitwardenEstablishedSession, Error>] = [:]
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

  private func makeSession(_ plan: Plan) -> NativeBitwardenEstablishedSession {
    let provider = NativeBitwardenTokenProvider()
    tokenProviders[plan.candidateID] = provider
    return NativeBitwardenEstablishedSession(
      id: plan.candidateID, accountID: plan.accountID,
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
  func didLock(_ id: UUID) -> Bool { locked.contains(id) }
  func didInitialize(_ id: UUID) -> Bool { initialized.contains(id) }
  func hasStartedLogin(_ id: UUID? = nil) -> Bool {
    id.map { loginStartedIDs.contains($0) } ?? !loginStartedIDs.isEmpty
  }
  func hasStartedCrypto(_ id: UUID) -> Bool { initialized.contains(id) }
  func token(for id: UUID) async -> String? { await tokenProviders[id]?.getAccessToken() }
}

@Suite @MainActor
struct NativeBitwardenControllerTests {
  #if canImport(ArcusisBitwardenSDK)
    @Test func acceptedSDKClientExecutesTypedCryptoClearAndRejectsUnknownHandle() async {
      let bridge = NativeBitwardenStateBridge()
      let client = Client(
        tokenProvider: NativeBitwardenTokenProvider(),
        settings: ClientSettings(
          identityUrl: "https://identity.example.test", apiUrl: "https://api.example.test",
          userAgent: "Arcusis Browser development smoke", deviceType: .sdk,
          deviceIdentifier: UUID().uuidString, bitwardenClientVersion: "0.1.0",
          bitwardenPackageType: "desktop"),
        managedSettings: ManagedSettingsBindingClient())
      client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
      client.crypto().clearUserCryptoKeys()
      #expect(!(await bridge.hasTransientKeyState()))

      let backend = NativeBitwardenSDKBackend()
      #expect(!(await backend.lock(sessionID: UUID())))
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

  @Test func loginMetadataUsesRegisteredDesktopClientTypeAndArcusisIdentity() {
    #expect(NativeBitwardenLoginRequestMetadata.clientID == "desktop")
    #expect(NativeBitwardenLoginRequestMetadata.userAgent == "Arcusis Browser")
    #expect(NativeBitwardenLoginRequestMetadata.deviceName == "Arcusis Browser")
  }

  @Test func profileSessionsRemainIndependentAndSettingsCloseClearsSecrets() async {
    let preferences = BrowserPreferencesStore()
    let first = UUID()
    let second = UUID()
    let backend = ControlledBitwardenBackend(mode: .waiting)
    let controller = NativeBitwardenController(preferences: preferences, backend: backend)
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
    let controller = NativeBitwardenController(preferences: preferences, backend: backend)
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
    let controller = NativeBitwardenController(
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
