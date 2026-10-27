import BrowserCore
import Foundation
import Synchronization

#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
  import Darwin
  import MachO
#endif

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
  case invalidSnapshot
  case unauthorized
  case syncFailed
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

struct NativeBitwardenRecoveryContext: Sendable {
  let email: String
  let identityURL: URL
  let apiURL: URL
  let deviceID: UUID
  let kdf: Data
  let wrappedAccountState: Data
  let masterPasswordUnlockData: Data
}

#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE && canImport(ArcusisBitwardenSDK)
  protocol NativeBitwardenRefreshBackend: NativeBitwardenBackend {
    func recoveryContext(sessionID: UUID) async throws -> NativeBitwardenRecoveryContext
    func restoreLocked(
      record: PasswordSessionRecoveryRecord, server: BitwardenServerConfiguration
    ) async throws -> UUID
    func unlockRestored(
      sessionID: UUID, record: PasswordSessionRecoveryRecord, password: String
    ) async throws -> NativeBitwardenEstablishedSession
    func refresh(
      sessionID: UUID, record: PasswordSessionRecoveryRecord
    ) async throws -> NativeBitwardenRefreshResponse
  }
#endif

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

actor NativeBitwardenSDKBackend: NativeBitwardenBackend, NativeBitwardenFillCredentialBackend {
  #if canImport(ArcusisBitwardenSDK)
    #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
      private let clientFactory: @Sendable (NativeBitwardenTokenProvider, ClientSettings) -> Client

      init(
        clientFactory:
          @escaping @Sendable (NativeBitwardenTokenProvider, ClientSettings) -> Client = {
            Client(tokenProvider: $0, settings: $1, managedSettings: ManagedSettingsBindingClient())
          }
      ) {
        NativeBitwardenLogging.bootstrap()
        self.clientFactory = clientFactory
      }
    #else
      init() { NativeBitwardenLogging.bootstrap() }
    #endif

    private struct Candidate {
      let client: Client
      let sync: SyncClientBinding
      let bridge: NativeBitwardenStateBridge
      let tokenProvider: NativeBitwardenTokenProvider
      let response: LoginSuccessResponse?
      let prelogin: PasswordPreloginResponse?
      let identityURL: URL
      let apiURL: URL
      let deviceID: UUID
      let restoredContext: NativeBitwardenRecoveryContext?
      var unlocking: Bool
      let email: String
      let userID: UUID
      var generation: Int
      var locked: Bool
      var initialized: Bool
      var fillAccess: NativeBitwardenFillAccessState<Cipher>
    }
    private var candidates: [UUID: Candidate] = [:]
  #endif

  #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
    static func isFixtureTestHost(executable: URL, bundles: [URL]) -> Bool {
      let path = executable.resolvingSymlinksInPath().path
      let runner = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        .resolvingSymlinksInPath().path
      return bundles.contains { bundle in
        let url = bundle.resolvingSymlinksInPath()
        guard url.pathExtension == "xctest" else { return false }
        return path == runner || path.hasPrefix(url.path + "/Contents/MacOS/")
      }
    }

    private static var fixtureHostAllowed: Bool {
      var pathBytes = [UInt8](repeating: 0, count: 4096)
      guard proc_pidpath(getpid(), &pathBytes, UInt32(pathBytes.count)) > 0 else { return false }
      let path = String(decoding: pathBytes.prefix { $0 != 0 }, as: UTF8.self)
      var bundles: [URL] = []
      for index in 0..<_dyld_image_count() {
        guard let name = _dyld_get_image_name(index) else { continue }
        let image = String(cString: name)
        guard let marker = image.range(of: ".xctest/Contents/MacOS/") else { continue }
        let bundlePath = String(image[..<marker.lowerBound]) + ".xctest"
        bundles.append(URL(fileURLWithPath: bundlePath))
      }
      return isFixtureTestHost(executable: URL(fileURLWithPath: path), bundles: bundles)
    }
  #endif

  var isAvailable: Bool {
    #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
      Self.fixtureHostAllowed
    #elseif canImport(ArcusisBitwardenSDK)
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
      #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
        guard Self.fixtureHostAllowed else { throw NativeBitwardenBackendError.sdkUnavailable }
      #endif
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
      #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
        let client = clientFactory(tokenProvider, settings)
        await client.requireFreshOrganizationSync()
      #else
        let client = Client(
          tokenProvider: tokenProvider, settings: settings,
          managedSettings: ManagedSettingsBindingClient())
      #endif
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
          response: response, prelogin: prelogin, identityURL: endpoints.identityURL,
          apiURL: endpoints.apiURL, deviceID: deviceID,
          restoredContext: nil, unlocking: false,
          email: email, userID: userID, generation: 0, locked: false, initialized: false,
          fillAccess: NativeBitwardenFillAccessState(sessionID: id))
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
      guard let candidate = candidates[candidateID], let response = candidate.response,
        let prelogin = candidate.prelogin,
        let wrappedState = response.wrappedAccountCryptoState,
        let unlockData = response.userDecryptionOptions.masterPasswordUnlock
      else { throw NativeBitwardenBackendError.unsupportedCryptoSetup }
      do {
        try await candidate.client.crypto().initializeUserCrypto(
          req: InitUserCryptoRequest(
            userId: candidate.userID.uuidString.lowercased(),
            kdfParams: prelogin.kdf,
            email: candidate.email,
            accountCryptographicState: wrappedState,
            method: .masterPasswordUnlock(
              password: password, masterPasswordUnlock: unlockData),
            upgradeToken: nil))
        let credential = PasswordCredential(
          accessToken: response.accessToken,
          refreshToken: response.refreshToken,
          expiresAt: Date(timeIntervalSince1970: Double(response.expiresAt) / 1_000))
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
      _ = candidate.fillAccess.revoke()
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
      guard var candidate = candidates[sessionID] else {
        throw NativeBitwardenBackendError.candidateUnavailable
      }
      candidate.generation += 1
      let ticket: NativeBitwardenSyncTicket
      do {
        ticket = try candidate.fillAccess.beginSync()
      } catch {
        candidates[sessionID] = candidate
        throw error
      }
      candidates[sessionID] = candidate
      defer {
        if var current = candidates[sessionID] {
          current.fillAccess.finishSync(ticket)
          candidates[sessionID] = current
        }
      }
      do {
        #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
          await candidate.client.requireFreshOrganizationSync()
          guard isCurrent(candidateID: sessionID, generation: candidate.generation) else {
            throw NativeBitwardenBackendError.staleSession
          }
        #endif
        try Task.checkCancellation()
        guard !candidate.locked, candidate.initialized,
          await candidate.tokenProvider.getAccessToken() != nil
        else { throw NativeBitwardenBackendError.sessionLocked }
        let generation = candidate.generation
        guard isCurrent(candidateID: sessionID, generation: generation) else {
          throw NativeBitwardenBackendError.staleSession
        }
        try Task.checkCancellation()
        #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE
          let outcome = await candidate.sync.syncWithOutcome(force: true)
          let synchronized: Bool
          switch outcome {
          case .synced: synchronized = true
          case .unchanged: synchronized = false
          case .unauthorized: throw NativeBitwardenBackendError.unauthorized
          case .failed: throw NativeBitwardenBackendError.syncFailed
          @unknown default: throw NativeBitwardenBackendError.syncFailed
          }
        #else
          let synchronized = try await candidate.sync.sync(force: true)
        #endif
        try Task.checkCancellation()
        guard isCurrent(candidateID: sessionID, generation: generation) else {
          throw NativeBitwardenBackendError.staleSession
        }
        try NativeBitwardenVaultSnapshot.requireCompletedSync(synchronized)
        #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
          let paired = candidate.sync.encryptedSnapshot()
          guard paired.generation > 0 else { throw NativeBitwardenBackendError.invalidSnapshot }
          let encrypted = paired.ciphers
          var organizationIDs: Set<UUID> = []
          for key in paired.organizationKeys.keys {
            guard let id = UUID(uuidString: key), organizationIDs.insert(id).inserted else {
              throw NativeBitwardenBackendError.invalidSnapshot
            }
          }
          try await candidate.client.crypto().initializeOrgCrypto(
            req: InitOrgCryptoRequest(organizationKeys: paired.organizationKeys))
          try Task.checkCancellation()
          guard isCurrent(candidateID: sessionID, generation: generation) else {
            throw NativeBitwardenBackendError.staleSession
          }
        #else
          let encrypted = candidate.sync.encryptedCiphers()
          let organizationIDs: Set<UUID> = []
        #endif
        guard encrypted.count <= NativeBitwardenVaultSnapshot.maximumCipherCount else {
          throw NativeBitwardenVaultSnapshotError.tooManyCiphers
        }
        var metadata: [NativeBitwardenVaultSnapshot.CipherMetadata] = []
        metadata.reserveCapacity(encrypted.count)
        let ciphers = candidate.client.vault().ciphers()
        for cipher in encrypted {
          #if !ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
            if cipher.organizationId != nil {
              metadata.append(
                NativeBitwardenVaultSnapshot.CipherMetadata(
                  id: cipher.id.flatMap(UUID.init(uuidString:)), name: "", username: nil, uris: [],
                  isLogin: false, isOrganization: true))
              continue
            }
          #endif
          let view = try await ciphers.decrypt(cipher: cipher)
          try Task.checkCancellation()
          guard isCurrent(candidateID: sessionID, generation: generation) else {
            throw NativeBitwardenBackendError.staleSession
          }
          try NativeBitwardenVaultSnapshot.validateOwnership(
            encryptedID: cipher.id, encryptedOrganizationID: cipher.organizationId,
            viewID: view.id, viewOrganizationID: view.organizationId,
            organizationIDs: organizationIDs)
          metadata.append(try NativeBitwardenVaultSnapshot.metadata(from: view))
        }
        guard isCurrent(candidateID: sessionID, generation: generation) else {
          throw NativeBitwardenBackendError.staleSession
        }
        let snapshot = try NativeBitwardenVaultSnapshot.make(
          from: metadata, organizationIDs: organizationIDs)
        var items: [UUID: Cipher] = [:]
        for cipher in encrypted {
          if let id = cipher.id.flatMap(UUID.init(uuidString:)) { items[id] = cipher }
        }
        try Task.checkCancellation()
        guard var current = candidates[sessionID],
          isCurrent(candidateID: sessionID, generation: generation)
        else { throw NativeBitwardenBackendError.staleSession }
        try current.fillAccess.publish(
          ticket: ticket, snapshot: snapshot, items: items, organizationIDs: organizationIDs)
        candidates[sessionID] = current
        return snapshot
      } catch {
        #if ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
          await candidate.client.requireFreshOrganizationSync()
        #endif
        throw error
      }
    #else
      _ = sessionID
      throw NativeBitwardenBackendError.sdkUnavailable
    #endif
  }

  func fillSnapshot(sessionID: UUID) async throws -> NativeBitwardenFillSnapshotAccess {
    #if canImport(ArcusisBitwardenSDK)
      guard let candidate = candidates[sessionID], !candidate.locked, candidate.initialized else {
        throw NativeBitwardenFillError.staleAccess
      }
      try Task.checkCancellation()
      return try candidate.fillAccess.snapshot()
    #else
      _ = sessionID
      throw NativeBitwardenBackendError.sdkUnavailable
    #endif
  }

  func fillCredential(
    access: NativeBitwardenFillAccess, cipherID: UUID, context: PasswordFillContext
  ) async throws -> NativeBitwardenFillCredential {
    #if canImport(ArcusisBitwardenSDK)
      guard let candidate = candidates[access.sessionID], !candidate.locked, candidate.initialized
      else { throw NativeBitwardenFillError.staleAccess }
      return try await NativeBitwardenFillLookup.credential(
        isolation: self, id: cipherID, origin: context.origin,
        item: {
          guard let current = self.candidates[access.sessionID], !current.locked,
            current.initialized
          else { throw NativeBitwardenFillError.staleAccess }
          let cipher = try current.fillAccess.item(access: access, id: cipherID)
          let organizationID = cipher.organizationId.flatMap(UUID.init(uuidString:))
          guard cipher.organizationId == nil || organizationID != nil else {
            throw NativeBitwardenFillError.ineligibleCipher
          }
          let ownership = try current.fillAccess.ownership(
            access: access, organizationID: organizationID)
          return (cipher, ownership)
        },
        decrypt: { item in
          let view = try await candidate.client.vault().ciphers().decrypt(cipher: item.0)
          return Self.fillCandidate(view)
        },
        ownership: { $0.1 },
        validate: {
          guard let current = self.candidates[access.sessionID], !current.locked,
            current.initialized
          else { throw NativeBitwardenFillError.staleAccess }
          try current.fillAccess.validate(access)
        })
    #else
      _ = (access, cipherID, context)
      throw NativeBitwardenBackendError.sdkUnavailable
    #endif
  }

  #if canImport(ArcusisBitwardenSDK)
    static func fillCandidate(_ view: CipherView) -> NativeBitwardenFillCandidate {
      let uris = (view.login?.uris ?? []).map { uri in
        let mode: NativeBitwardenFillURIMode
        switch uri.match {
        case .host: mode = .host
        case .never: mode = .never
        case .domain, .startsWith, .exact, .regularExpression, nil: mode = .unsupported
        @unknown default: mode = .unsupported
        }
        return NativeBitwardenFillURI(value: uri.uri, mode: mode)
      }
      return NativeBitwardenFillCandidate(
        id: view.id.flatMap(UUID.init(uuidString:)), organization: view.organizationId != nil,
        organizationID: view.organizationId.flatMap(UUID.init(uuidString:)),
        login: view.type == .login, deleted: view.deletedDate != nil,
        archived: view.archivedDate != nil, partial: view.partial, viewPassword: view.viewPassword,
        reprompt: view.reprompt != .none, username: view.login?.username,
        password: view.login?.password, uris: uris)
    }

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

#if ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE && canImport(ArcusisBitwardenSDK)
  extension NativeBitwardenSDKBackend: NativeBitwardenRefreshBackend {
    func recoveryContext(sessionID: UUID) throws -> NativeBitwardenRecoveryContext {
      guard let candidate = candidates[sessionID], candidate.initialized, !candidate.locked,
        let response = candidate.response, let prelogin = candidate.prelogin,
        let wrapped = response.wrappedAccountCryptoState,
        let unlock = response.userDecryptionOptions.masterPasswordUnlock
      else { throw NativeBitwardenBackendError.sessionLocked }
      let encoder = JSONEncoder()
      return try NativeBitwardenRecoveryContext(
        email: candidate.email, identityURL: candidate.identityURL, apiURL: candidate.apiURL,
        deviceID: candidate.deviceID, kdf: encoder.encode(prelogin.kdf),
        wrappedAccountState: encoder.encode(wrapped),
        masterPasswordUnlockData: encoder.encode(unlock))
    }

    func restoreLocked(
      record: PasswordSessionRecoveryRecord, server: BitwardenServerConfiguration
    ) async throws -> UUID {
      #if ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
        guard Self.fixtureHostAllowed else { throw NativeBitwardenBackendError.sdkUnavailable }
      #endif
      guard record.state == .ready else { throw NativeBitwardenBackendError.sessionLocked }
      let endpoints = try server.endpoints()
      guard endpoints.identityURL == record.identityURL, endpoints.apiURL == record.apiURL,
        endpoints.stableServiceID == record.serviceID,
        record.clientID == NativeBitwardenLoginRequestMetadata.clientID
      else { throw NativeBitwardenBackendError.staleSession }
      let decoder = JSONDecoder()
      _ = try decoder.decode(Kdf.self, from: record.kdf)
      _ = try decoder.decode(
        WrappedAccountCryptographicState.self, from: record.wrappedAccountState)
      _ = try decoder.decode(MasterPasswordUnlockData.self, from: record.masterPasswordUnlockData)
      let settings = ClientSettings(
        identityUrl: endpoints.identityURL.absoluteString, apiUrl: endpoints.apiURL.absoluteString,
        userAgent: NativeBitwardenLoginRequestMetadata.userAgent, deviceType: .sdk,
        deviceIdentifier: record.deviceID.uuidString.lowercased(),
        bitwardenClientVersion: NativeBitwardenLoginRequestMetadata.clientVersion,
        bitwardenPackageType: "desktop")
      let provider = NativeBitwardenTokenProvider()
      let bridge = NativeBitwardenStateBridge()
      let client = clientFactory(provider, settings)
      await client.requireFreshOrganizationSync()
      client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
      let id = UUID()
      let context = NativeBitwardenRecoveryContext(
        email: record.email, identityURL: record.identityURL, apiURL: record.apiURL,
        deviceID: record.deviceID, kdf: record.kdf, wrappedAccountState: record.wrappedAccountState,
        masterPasswordUnlockData: record.masterPasswordUnlockData)
      candidates[id] = Candidate(
        client: client, sync: client.sync(), bridge: bridge, tokenProvider: provider,
        response: nil, prelogin: nil, identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
        deviceID: record.deviceID, restoredContext: context, unlocking: false,
        email: record.email, userID: record.accountID, generation: 0,
        locked: true, initialized: false, fillAccess: NativeBitwardenFillAccessState(sessionID: id))
      return id
    }

    func unlockRestored(
      sessionID: UUID, record: PasswordSessionRecoveryRecord, password: String
    ) async throws -> NativeBitwardenEstablishedSession {
      guard var candidate = candidates[sessionID], candidate.locked, !candidate.unlocking,
        let context = candidate.restoredContext, candidate.userID == record.accountID,
        candidate.identityURL == record.identityURL, candidate.apiURL == record.apiURL,
        candidate.deviceID == record.deviceID, candidate.email == record.email,
        context.kdf == record.kdf, context.wrappedAccountState == record.wrappedAccountState,
        context.masterPasswordUnlockData == record.masterPasswordUnlockData, record.state == .ready
      else { throw NativeBitwardenBackendError.staleSession }
      candidate.unlocking = true
      candidate.generation += 1
      let generation = candidate.generation
      candidates[sessionID] = candidate
      do {
        let decoder = JSONDecoder()
        let kdf = try decoder.decode(Kdf.self, from: context.kdf)
        let wrapped = try decoder.decode(
          WrappedAccountCryptographicState.self, from: context.wrappedAccountState)
        let unlock = try decoder.decode(
          MasterPasswordUnlockData.self, from: context.masterPasswordUnlockData)
        try await candidate.client.crypto().initializeUserCrypto(
          req: InitUserCryptoRequest(
            userId: candidate.userID.uuidString.lowercased(), kdfParams: kdf, email: context.email,
            accountCryptographicState: wrapped,
            method: .masterPasswordUnlock(password: password, masterPasswordUnlock: unlock),
            upgradeToken: nil))
        guard var current = candidates[sessionID], current.generation == generation,
          current.unlocking, current.locked, !Task.isCancelled
        else { throw NativeBitwardenBackendError.staleSession }
        current.unlocking = false
        current.locked = false
        current.initialized = true
        candidates[sessionID] = current
        return NativeBitwardenEstablishedSession(
          id: sessionID, accountID: candidate.userID, credential: record.credential,
          tokenProvider: candidate.tokenProvider)
      } catch {
        candidate.client.crypto().clearUserCryptoKeys()
        _ = await candidate.bridge.clearTransientKeyState()
        if var current = candidates[sessionID], current.generation == generation {
          current.unlocking = false
          candidates[sessionID] = current
        }
        throw error
      }
    }

    func refresh(
      sessionID: UUID, record: PasswordSessionRecoveryRecord
    ) async throws -> NativeBitwardenRefreshResponse {
      guard let candidate = candidates[sessionID], !candidate.locked, candidate.initialized,
        candidate.userID == record.accountID, candidate.identityURL == record.identityURL,
        candidate.apiURL == record.apiURL, candidate.deviceID == record.deviceID,
        candidate.email == record.email,
        record.clientID == NativeBitwardenLoginRequestMetadata.clientID,
        let token = record.credential.refreshToken
      else { throw NativeBitwardenBackendError.staleSession }
      let kdf = try JSONDecoder().decode(Kdf.self, from: record.kdf)
      if let prelogin = candidate.prelogin {
        guard prelogin.kdf == kdf else { throw NativeBitwardenBackendError.staleSession }
      } else {
        guard candidate.restoredContext?.kdf == record.kdf else {
          throw NativeBitwardenBackendError.staleSession
        }
      }
      let result = try await candidate.client.auth().refreshPasswordManagerToken(
        refreshToken: token, clientId: record.clientID, email: record.email, kdf: kdf)
      guard isCurrent(candidateID: sessionID, generation: candidate.generation), !Task.isCancelled
      else { throw NativeBitwardenBackendError.staleSession }
      return NativeBitwardenRefreshResponse(
        accessToken: result.accessToken, refreshToken: result.refreshToken,
        expiresIn: result.expiresIn)
    }
  }
#endif

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
