import BrowserCore
import Foundation
import Synchronization

#if canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
#endif

enum NativeBitwardenBackendError: Error, Equatable, Sendable {
  case sdkUnavailable
  case invalidAccessToken
  case unsupportedCryptoSetup
  case candidateUnavailable
  case sessionLocked
  case staleSession
}

enum NativeBitwardenLoginRequestMetadata {
  static let clientID = "desktop"
  static let clientVersion = "0.1.0"
  static let userAgent = "Arcusis Browser"
  static let deviceName = "Arcusis Browser"
}

enum NativeBitwardenMFAProvider: String, CaseIterable, Sendable, Identifiable {
  case authenticator, email, yubikey

  var id: Self { self }
  var title: String {
    switch self {
    case .authenticator: "Authenticator app"
    case .email: "Email code"
    case .yubikey: "YubiKey OTP"
    }
  }
}

struct NativeBitwardenSecondFactor: Sendable {
  let provider: NativeBitwardenMFAProvider
  let token: String
}

enum NativeBitwardenLoginResult: Sendable {
  case challenge(UUID, [NativeBitwardenMFAProvider])
  case authenticated(NativeBitwardenAuthenticatedCandidate)
}

struct NativeBitwardenAuthenticatedCandidate: Sendable {
  let id: UUID
  let accountID: UUID
}

struct NativeBitwardenEstablishedSession: Sendable {
  let id: UUID
  let accountID: UUID
  let credential: PasswordCredential
  let tokenProvider: NativeBitwardenTokenProvider
}

protocol NativeBitwardenBackend: Sendable {
  var isAvailable: Bool { get async }
  func login(
    server: BitwardenServerConfiguration, email: String, password: String,
    deviceID: UUID, secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult
  func initializeCrypto(candidateID: UUID, password: String) async throws
    -> NativeBitwardenEstablishedSession
  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot
  func lock(sessionID: UUID) async -> Bool
  func discard(sessionID: UUID) async
}

/// In-memory SDK callback only; PasswordCredentialStore owns persisted credentials.
final class NativeBitwardenTokenProvider: Sendable {
  private let accessToken = Mutex<String?>(nil)
  func getAccessToken() async -> String? { accessToken.withLock { $0 } }
  func publish(_ token: String) { accessToken.withLock { $0 = token } }
  func clear() { accessToken.withLock { $0 = nil } }
}

#if canImport(ArcusisBitwardenSDK)
  extension NativeBitwardenTokenProvider: ClientManagedTokens {}
#endif

enum NativeBitwardenAccessTokenIdentity {
  private struct Claims: Decodable { let sub: String }

  static func userID(from token: String) throws -> UUID {
    guard token.utf8.count <= 32_768 else { throw NativeBitwardenBackendError.invalidAccessToken }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty,
      parts.allSatisfy({ $0.utf8.count <= 16_384 }),
      parts.allSatisfy({ $0.utf8.allSatisfy(isBase64URLByte) })
    else { throw NativeBitwardenBackendError.invalidAccessToken }

    let payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: padded), data.count <= 12_288,
      let claims = try? JSONDecoder().decode(Claims.self, from: data),
      let id = UUID(uuidString: claims.sub)
    else { throw NativeBitwardenBackendError.invalidAccessToken }
    return id
  }

  private static func isBase64URLByte(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
      || byte == 45 || byte == 95 || byte == 61
  }
}

actor NativeBitwardenSDKBackend: NativeBitwardenBackend {
  #if canImport(ArcusisBitwardenSDK)
    private struct Candidate {
      let client: Client
      let sync: SyncClientBinding
      let bridge: NativeBitwardenStateBridge
      let tokenProvider: NativeBitwardenTokenProvider
      let response: LoginSuccessResponse
      let prelogin: PasswordPreloginResponse
      let email: String
      let userID: UUID
      var generation: Int
      var locked: Bool
      var initialized: Bool
    }
    private var candidates: [UUID: Candidate] = [:]
  #endif

  var isAvailable: Bool {
    #if canImport(ArcusisBitwardenSDK)
      true
    #else
      false
    #endif
  }

  func login(
    server: BitwardenServerConfiguration, email: String, password: String,
    deviceID: UUID, secondFactor: NativeBitwardenSecondFactor?
  ) async throws -> NativeBitwardenLoginResult {
    #if canImport(ArcusisBitwardenSDK)
      let endpoints = try server.endpoints()
      let settings = ClientSettings(
        identityUrl: endpoints.identityURL.absoluteString,
        apiUrl: endpoints.apiURL.absoluteString,
        userAgent: NativeBitwardenLoginRequestMetadata.userAgent,
        deviceType: .sdk,
        deviceIdentifier: deviceID.uuidString.lowercased(),
        bitwardenClientVersion: NativeBitwardenLoginRequestMetadata.clientVersion,
        bitwardenPackageType: "desktop")
      let tokenProvider = NativeBitwardenTokenProvider()
      let bridge = NativeBitwardenStateBridge()
      let client = Client(
        tokenProvider: tokenProvider, settings: settings,
        managedSettings: ManagedSettingsBindingClient())
      client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
      let login = client.auth().login()
      let prelogin = try await login.getPasswordPrelogin(email: email)
      let sdkFactor: TwoFactorRequest?
      if let secondFactor {
        sdkFactor = TwoFactorRequest(
          token: secondFactor.token,
          provider: sdkProvider(secondFactor.provider), remember: false)
      } else {
        sdkFactor = nil
      }
      let request = PasswordLoginRequest(
        loginRequest: LoginRequest(
          clientId: NativeBitwardenLoginRequestMetadata.clientID,
          device: LoginDeviceRequest(
            deviceType: .sdk, deviceIdentifier: deviceID.uuidString.lowercased(),
            deviceName: NativeBitwardenLoginRequestMetadata.deviceName, devicePushToken: nil)),
        email: email, password: password, preloginResponse: prelogin, twoFactor: sdkFactor)
      switch try await login.loginViaPassword(request: request) {
      case .twoFactorRequired(let challenge):
        let providers = challenge.providers.compactMap(nativeProvider)
        return .challenge(UUID(), providers)
      case .authenticated(let response):
        // Subject supplies account metadata only after typed SDK login succeeds.
        let userID = try NativeBitwardenAccessTokenIdentity.userID(from: response.accessToken)
        let id = UUID()
        candidates[id] = Candidate(
          client: client, sync: client.sync(), bridge: bridge, tokenProvider: tokenProvider,
          response: response, prelogin: prelogin, email: email, userID: userID,
          generation: 0, locked: false, initialized: false)
        return .authenticated(NativeBitwardenAuthenticatedCandidate(id: id, accountID: userID))
      }
    #else
      _ = (server, email, password, deviceID, secondFactor)
      throw NativeBitwardenBackendError.sdkUnavailable
    #endif
  }

  func initializeCrypto(
    candidateID: UUID, password: String
  ) async throws -> NativeBitwardenEstablishedSession {
    #if canImport(ArcusisBitwardenSDK)
      guard let candidate = candidates[candidateID],
        let wrappedState = candidate.response.wrappedAccountCryptoState,
        let unlockData = candidate.response.userDecryptionOptions.masterPasswordUnlock
      else { throw NativeBitwardenBackendError.unsupportedCryptoSetup }
      do {
        try await candidate.client.crypto().initializeUserCrypto(
          req: InitUserCryptoRequest(
            userId: candidate.userID.uuidString.lowercased(),
            kdfParams: candidate.prelogin.kdf,
            email: candidate.email,
            accountCryptographicState: wrappedState,
            method: .masterPasswordUnlock(
              password: password, masterPasswordUnlock: unlockData),
            upgradeToken: nil))
        let credential = PasswordCredential(
          accessToken: candidate.response.accessToken,
          refreshToken: candidate.response.refreshToken,
          expiresAt: Date(timeIntervalSince1970: Double(candidate.response.expiresAt) / 1_000))
        guard var current = candidates[candidateID], !current.locked else {
          throw NativeBitwardenBackendError.staleSession
        }
        current.initialized = true
        candidates[candidateID] = current
        return NativeBitwardenEstablishedSession(
          id: candidateID, accountID: candidate.userID, credential: credential,
          tokenProvider: candidate.tokenProvider)
      } catch {
        await clearCandidate(candidateID, candidate: candidate)
        throw error
      }
    #else
      _ = (candidateID, password)
      throw NativeBitwardenBackendError.sdkUnavailable
    #endif
  }

  func lock(sessionID: UUID) async -> Bool {
    #if canImport(ArcusisBitwardenSDK)
      guard var candidate = candidates[sessionID] else { return false }
      candidate.generation += 1
      candidate.locked = true
      candidates[sessionID] = candidate
      candidate.client.crypto().clearUserCryptoKeys()
      let hadState = await candidate.bridge.hasTransientKeyState()
      let cleared = await candidate.bridge.clearTransientKeyState()
      let remains = await candidate.bridge.hasTransientKeyState()
      return (!hadState || cleared) && !remains
    #else
      _ = sessionID
      return false
    #endif
  }

  func discard(sessionID: UUID) async {
    #if canImport(ArcusisBitwardenSDK)
      guard let candidate = candidates.removeValue(forKey: sessionID) else { return }
      await clearCandidate(sessionID, candidate: candidate)
    #else
      _ = sessionID
    #endif
  }

  func syncVault(sessionID: UUID) async throws -> NativeBitwardenVaultSnapshot {
    #if canImport(ArcusisBitwardenSDK)
      guard let candidate = candidates[sessionID] else {
        throw NativeBitwardenBackendError.candidateUnavailable
      }
      guard !candidate.locked, candidate.initialized,
        await candidate.tokenProvider.getAccessToken() != nil
      else { throw NativeBitwardenBackendError.sessionLocked }
      let generation = candidate.generation
      guard isCurrent(candidateID: sessionID, generation: generation) else {
        throw NativeBitwardenBackendError.staleSession
      }
      let synchronized = try await candidate.sync.sync(force: true)
      guard isCurrent(candidateID: sessionID, generation: generation) else {
        throw NativeBitwardenBackendError.staleSession
      }
      try NativeBitwardenVaultSnapshot.requireCompletedSync(synchronized)
      let encrypted = candidate.sync.encryptedCiphers()
      guard encrypted.count <= NativeBitwardenVaultSnapshot.maximumCipherCount else {
        throw NativeBitwardenVaultSnapshotError.tooManyCiphers
      }
      var metadata: [NativeBitwardenVaultSnapshot.CipherMetadata] = []
      metadata.reserveCapacity(encrypted.count)
      let ciphers = candidate.client.vault().ciphers()
      for cipher in encrypted {
        if cipher.organizationId != nil {
          metadata.append(
            NativeBitwardenVaultSnapshot.CipherMetadata(
              id: cipher.id.flatMap(UUID.init(uuidString:)), name: "", username: nil, uris: [],
              isLogin: false, isOrganization: true))
          continue
        }
        let view = try await ciphers.decrypt(cipher: cipher)
        guard isCurrent(candidateID: sessionID, generation: generation) else {
          throw NativeBitwardenBackendError.staleSession
        }
        metadata.append(try NativeBitwardenVaultSnapshot.metadata(from: view))
      }
      guard isCurrent(candidateID: sessionID, generation: generation) else {
        throw NativeBitwardenBackendError.staleSession
      }
      return try NativeBitwardenVaultSnapshot.make(from: metadata)
    #else
      _ = sessionID
      throw NativeBitwardenBackendError.sdkUnavailable
    #endif
  }

  #if canImport(ArcusisBitwardenSDK)
    private func sdkProvider(_ provider: NativeBitwardenMFAProvider) -> TwoFactorProvider {
      switch provider {
      case .authenticator: .authenticator
      case .email: .email
      case .yubikey: .yubikey
      }
    }

    private func nativeProvider(_ provider: TwoFactorProvider) -> NativeBitwardenMFAProvider? {
      switch provider {
      case .authenticator: .authenticator
      case .email: .email
      case .yubikey: .yubikey
      case .duo, .u2f, .remember, .organizationDuo, .webAuthn: nil
      @unknown default: nil
      }
    }

    private func clearCandidate(_ id: UUID, candidate: Candidate) async {
      candidates.removeValue(forKey: id)
      candidate.tokenProvider.clear()
      candidate.client.crypto().clearUserCryptoKeys()
      _ = await candidate.bridge.clearTransientKeyState()
    }

    private func isCurrent(candidateID: UUID, generation: Int) -> Bool {
      guard let current = candidates[candidateID] else { return false }
      return !current.locked && current.initialized && current.generation == generation
    }
  #endif
}

#if canImport(ArcusisBitwardenSDK)
  actor NativeBitwardenStateBridge: StateBridgeForeignImpl {
    private var userKey: SymmetricCryptoKey?
    private var userKeyID: KeyId?
    private var persistentPINEnvelope: PasswordProtectedKeyEnvelope?
    private var ephemeralPINEnvelope: PasswordProtectedKeyEnvelope?
    private var encryptedPIN: EncString?
    private var upgradeToken: V2UpgradeToken?
    private var accountCryptoState: WrappedAccountCryptographicState?
    private var masterPasswordUnlockData: MasterPasswordUnlockData?
    private var webauthnPRFUnlockData: WebAuthnPrfUnlockData?
    private var kdfConfig: Kdf?
    private var v2GracePeriodStart: V2EncryptedMigrationsGracePeriodStart?

    func setUserKey(value: SymmetricCryptoKey) async { userKey = value }
    func getUserKey() async -> SymmetricCryptoKey? { userKey }
    func clearUserKey() async { userKey = nil }
    func setUserKeyId(value: KeyId) async { userKeyID = value }
    func getUserKeyId() async -> KeyId? { userKeyID }
    func clearUserKeyId() async { userKeyID = nil }
    func setPersistentPinEnvelope(value: PasswordProtectedKeyEnvelope) async {
      persistentPINEnvelope = value
    }
    func getPersistentPinEnvelope() async -> PasswordProtectedKeyEnvelope? { persistentPINEnvelope }
    func clearPersistentPinEnvelope() async { persistentPINEnvelope = nil }
    func setEphemeralPinEnvelope(value: PasswordProtectedKeyEnvelope) async {
      ephemeralPINEnvelope = value
    }
    func getEphemeralPinEnvelope() async -> PasswordProtectedKeyEnvelope? { ephemeralPINEnvelope }
    func clearEphemeralPinEnvelope() async { ephemeralPINEnvelope = nil }
    func setEncryptedPin(value: EncString) async { encryptedPIN = value }
    func getEncryptedPin() async -> EncString? { encryptedPIN }
    func clearEncryptedPin() async { encryptedPIN = nil }
    func setV2UpgradeToken(value: V2UpgradeToken) async { upgradeToken = value }
    func getV2UpgradeToken() async -> V2UpgradeToken? { upgradeToken }
    func clearV2UpgradeToken() async { upgradeToken = nil }
    func setAccountCryptographicState(value: WrappedAccountCryptographicState) async {
      accountCryptoState = value
    }
    func getAccountCryptographicState() async -> WrappedAccountCryptographicState? {
      accountCryptoState
    }
    func clearAccountCryptographicState() async { accountCryptoState = nil }
    func setMasterpasswordUnlockData(value: MasterPasswordUnlockData) async {
      masterPasswordUnlockData = value
    }
    func getMasterpasswordUnlockData() async -> MasterPasswordUnlockData? {
      masterPasswordUnlockData
    }
    func clearMasterpasswordUnlockData() async { masterPasswordUnlockData = nil }
    func setWebauthnPrfUnlockData(value: WebAuthnPrfUnlockData) async {
      webauthnPRFUnlockData = value
    }
    func getWebauthnPrfUnlockData() async -> WebAuthnPrfUnlockData? { webauthnPRFUnlockData }
    func clearWebauthnPrfUnlockData() async { webauthnPRFUnlockData = nil }
    func setKdfConfig(value: Kdf) async { kdfConfig = value }
    func getKdfConfig() async -> Kdf? { kdfConfig }
    func clearKdfConfig() async { kdfConfig = nil }
    func setV2EncryptedMigrationsGracePeriodStart(value: V2EncryptedMigrationsGracePeriodStart)
      async
    {
      v2GracePeriodStart = value
    }
    func getV2EncryptedMigrationsGracePeriodStart() async -> V2EncryptedMigrationsGracePeriodStart?
    {
      v2GracePeriodStart
    }
    func clearV2EncryptedMigrationsGracePeriodStart() async { v2GracePeriodStart = nil }

    func hasTransientKeyState() -> Bool {
      userKey != nil || userKeyID != nil || persistentPINEnvelope != nil
        || ephemeralPINEnvelope != nil || encryptedPIN != nil || upgradeToken != nil
        || accountCryptoState != nil || masterPasswordUnlockData != nil
        || webauthnPRFUnlockData != nil || kdfConfig != nil || v2GracePeriodStart != nil
    }

    func clearTransientKeyState() -> Bool {
      let hadState = hasTransientKeyState()
      userKey = nil
      userKeyID = nil
      persistentPINEnvelope = nil
      ephemeralPINEnvelope = nil
      encryptedPIN = nil
      upgradeToken = nil
      accountCryptoState = nil
      masterPasswordUnlockData = nil
      webauthnPRFUnlockData = nil
      kdfConfig = nil
      v2GracePeriodStart = nil
      return hadState && !hasTransientKeyState()
    }
  }
#endif
