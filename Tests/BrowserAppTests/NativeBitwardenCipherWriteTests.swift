#if canImport(ArcusisBitwardenSDK) && ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE
  import Foundation
  import XCTest
  import ArcusisBitwardenSDK
  import BrowserCore

  @testable import ArcusisBrowser

  private struct CipherWriteFixture: Decodable {
    let endpoint: String
    let email: String
    let userID: String
    let currentPassword: String
    let privateKey: String
    let wrappedUserKey: String
    let iterations: UInt32
    let sizeCase: String?
  }

  final class NativeBitwardenCipherWriteTests: XCTestCase {
    func testOwnedBackendRepositoryLifecycle() async throws {
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_CIPHER_WRITE_FIXTURE"])
      let fixture = try JSONDecoder().decode(
        CipherWriteFixture.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
      let endpoint = try XCTUnwrap(URL(string: fixture.endpoint))
      guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path.isEmpty, endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else {
        XCTFail("Invalid owned endpoint")
        return
      }
      let configuration = BitwardenServerConfiguration(
        region: .custom, customBaseURL: "https://fixture.example")
      let backend = NativeBitwardenSDKBackend { provider, settings in
        let local = ClientSettings(
          identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
          userAgent: settings.userAgent, deviceType: .sdk,
          deviceIdentifier: settings.deviceIdentifier,
          bitwardenClientVersion: settings.bitwardenClientVersion,
          bitwardenPackageType: settings.bitwardenPackageType)
        return Client(
          tokenProvider: provider, settings: local, managedSettings: ManagedSettingsBindingClient())
      }
      guard await backend.isAvailable else {
        XCTFail("Fixture host guard rejected test")
        return
      }
      let device = UUID()
      let result = try await backend.login(
        server: configuration, email: fixture.email, password: fixture.currentPassword,
        deviceID: device, secondFactor: nil)
      guard case .authenticated(let candidate) = result else {
        XCTFail("Synthetic login did not authenticate")
        return
      }
      let loginRepository = await backend.cipherRepositoryForFixture(sessionID: candidate.id)
      let loginStage = try XCTUnwrap(loginRepository)
      let session = try await backend.initializeCrypto(
        candidateID: candidate.id, password: fixture.currentPassword)
      XCTAssertThrowsError(try loginStage.acceptSnapshot([]))
      session.tokenProvider.publish(session.credential.accessToken)
      let cryptoRepository = await backend.cipherRepositoryForFixture(sessionID: candidate.id)
      let cryptoStage = try XCTUnwrap(cryptoRepository)
      let firstSnapshot = try await backend.syncVault(sessionID: session.id)
      XCTAssertEqual(firstSnapshot.logins.count, 1)
      XCTAssertThrowsError(try cryptoStage.acceptSnapshot([]))
      let firstRepository = await backend.cipherRepositoryForFixture(sessionID: candidate.id)
      let first = try XCTUnwrap(firstRepository)
      let firstItems = try await first.list()
      XCTAssertEqual(firstItems.count, 1)
      let access = try await backend.fillSnapshot(sessionID: session.id).access
      let cipherIDString = try XCTUnwrap(firstItems.first?.id)
      let cipherID = try XCTUnwrap(UUID(uuidString: cipherIDString))
      let fillContext = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
        origin: PasswordFillOrigin("https://fixture.example")!)
      let credential = try await backend.fillCredential(
        access: access, cipherID: cipherID, context: fillContext)
      XCTAssertEqual(credential.username, "fixture-write-user")
      XCTAssertEqual(credential.password, "fixture-write-second")
      _ = try await backend.syncVault(sessionID: session.id)
      let secondRepository = await backend.cipherRepositoryForFixture(sessionID: candidate.id)
      let second = try XCTUnwrap(secondRepository)
      XCTAssertNotEqual(first.ownerID, second.ownerID)
      do {
        _ = try await first.list()
        XCTFail("Prior repository remained active")
      } catch {}
      do {
        _ = try await backend.fillCredential(
          access: access, cipherID: cipherID, context: fillContext)
        XCTFail("Stale access accepted")
      } catch let error as NativeBitwardenFillError {
        XCTAssertEqual(error, .staleAccess)
      }
      do {
        _ = try await backend.syncVault(sessionID: session.id)
        XCTFail("Failed sync accepted")
      } catch {}
      let failedRepository = await backend.cipherRepositoryForFixture(sessionID: candidate.id)
      let failed = try XCTUnwrap(failedRepository)
      do {
        _ = try await second.list()
        XCTFail("Prior repository survived failed sync")
      } catch {}
      XCTAssertThrowsError(try failed.acceptSnapshot([]))
      let context = try await backend.recoveryContext(sessionID: session.id)
      let endpoints = try configuration.endpoints()
      let record = try PasswordSessionRecoveryRecord(
        binding: PasswordAuthenticationBinding(
          profileID: UUID(), vaultID: UUID(), accountID: session.accountID,
          authority: endpoints.credentialAuthority),
        identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
        serviceID: endpoints.stableServiceID, deviceID: device,
        clientID: NativeBitwardenLoginRequestMetadata.clientID, email: context.email,
        sdkRevision: "synthetic", kdf: context.kdf,
        wrappedAccountState: context.wrappedAccountState,
        masterPasswordUnlockData: context.masterPasswordUnlockData,
        credential: session.credential, revision: 0, state: .ready)
      let didLock = await backend.lock(sessionID: session.id)
      XCTAssertTrue(didLock)
      await backend.discard(sessionID: session.id)
      let restored = try await backend.restoreLocked(record: record, server: configuration)
      let restoredRepository = await backend.cipherRepositoryForFixture(sessionID: restored)
      let restoredStage = try XCTUnwrap(restoredRepository)
      _ = try await backend.unlockRestored(
        sessionID: restored, record: record, password: fixture.currentPassword)
      XCTAssertThrowsError(try restoredStage.acceptSnapshot([]))
      let unlockedRepository = await backend.cipherRepositoryForFixture(sessionID: restored)
      let unlocked = try XCTUnwrap(unlockedRepository)
      let restoredLock = await backend.lock(sessionID: restored)
      XCTAssertTrue(restoredLock)
      XCTAssertThrowsError(try unlocked.acceptSnapshot([]))
      _ = try await backend.unlockRestored(
        sessionID: restored, record: record, password: fixture.currentPassword)
      let reunlockedRepository = await backend.cipherRepositoryForFixture(sessionID: restored)
      let reunlocked = try XCTUnwrap(reunlockedRepository)
      XCTAssertNotEqual(unlocked.ownerID, reunlocked.ownerID)
      await backend.discard(sessionID: restored)
      XCTAssertThrowsError(try reunlocked.acceptSnapshot([]))
    }

    func testOwnedBackendReadWhenWritableLimitExceeded() async throws {
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_CIPHER_WRITE_FIXTURE"])
      let fixture = try JSONDecoder().decode(
        CipherWriteFixture.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
      guard let sizeCase = fixture.sizeCase, ["single", "aggregate"].contains(sizeCase),
        let endpoint = URL(string: fixture.endpoint), endpoint.scheme == "http",
        endpoint.host == "127.0.0.1", endpoint.port != nil, endpoint.path.isEmpty,
        endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
        endpoint.fragment == nil
      else { return XCTFail("Invalid owned size fixture") }
      let provider = NativeBitwardenTokenProvider()
      provider.publish("synthetic-owned-token")
      let raw = Client(
        tokenProvider: provider,
        settings: ClientSettings(
          identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
          userAgent: "Arcusis fixture", deviceType: .sdk, deviceIdentifier: UUID().uuidString,
          bitwardenClientVersion: "0.1.0", bitwardenPackageType: "desktop"),
        managedSettings: ManagedSettingsBindingClient())
      let bridge = NativeBitwardenStateBridge()
      raw.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
      let repository = NativeBitwardenCipherRepository()
      try repository.acceptSnapshot([])
      raw.platform().state().registerClientManagedRepositories(
        repositories: Repositories(
          cipher: repository, folder: nil, localUserDataKeyState: nil, organizationSharedKey: nil,
          send: nil, policy: nil, organization: nil))
      let kdf = Kdf.pbkdf2(iterations: fixture.iterations)
      try await raw.crypto().initializeUserCrypto(
        req: InitUserCryptoRequest(
          userId: fixture.userID, kdfParams: kdf, email: fixture.email,
          accountCryptographicState: .v1(privateKey: fixture.privateKey),
          method: .masterPasswordUnlock(
            password: fixture.currentPassword,
            masterPasswordUnlock: MasterPasswordUnlockData(
              kdf: kdf,
              masterKeyWrappedUserKey: fixture.wrappedUserKey, salt: fixture.email,
              containedKeyId: nil)),
          upgradeToken: nil))
      defer {
        repository.revoke()
        raw.crypto().clearUserCryptoKeys()
        provider.clear()
      }
      let count = sizeCase == "single" ? 1 : 18
      let note = String(repeating: "x", count: sizeCase == "single" ? 850_000 : 720_000)
      let login = LoginView(
        username: "fixture-write-user", password: "fixture-write-second",
        passwordRevisionDate: nil,
        uris: [LoginUriView(uri: "https://fixture.example/login", match: .host, uriChecksum: nil)],
        totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil)
      var rejected = 0
      for _ in 0..<count {
        do {
          _ = try await raw.vault().ciphers().create(
            request: CipherCreateRequest(
              organizationId: nil, collectionIds: [], folderId: nil, name: "fixture-name",
              notes: note,
              favorite: false, reprompt: .none, type: .login(login), fields: [], archivedDate: nil))
        } catch { rejected += 1 }
      }
      XCTAssertGreaterThan(rejected, 0, "SDK repository limit was not exercised")
      let configuration = BitwardenServerConfiguration(
        region: .custom, customBaseURL: "https://fixture.example")
      let backend = NativeBitwardenSDKBackend { provider, settings in
        Client(
          tokenProvider: provider,
          settings: ClientSettings(
            identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
            userAgent: settings.userAgent, deviceType: .sdk,
            deviceIdentifier: settings.deviceIdentifier,
            bitwardenClientVersion: settings.bitwardenClientVersion,
            bitwardenPackageType: settings.bitwardenPackageType),
          managedSettings: ManagedSettingsBindingClient())
      }
      guard await backend.isAvailable else { return XCTFail("Fixture host guard rejected test") }
      let result = try await backend.login(
        server: configuration, email: fixture.email,
        password: fixture.currentPassword, deviceID: UUID(), secondFactor: nil)
      guard case .authenticated(let candidate) = result else {
        return XCTFail("Synthetic login failed")
      }
      let session = try await backend.initializeCrypto(
        candidateID: candidate.id, password: fixture.currentPassword)
      session.tokenProvider.publish(session.credential.accessToken)
      let snapshot = try await backend.syncVault(sessionID: session.id)
      XCTAssertEqual(snapshot.logins.count, count)
      let access = try await backend.fillSnapshot(sessionID: session.id)
      let id = try XCTUnwrap(snapshot.logins.first?.id)
      let context = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
        origin: PasswordFillOrigin("https://fixture.example")!)
      let credential = try await backend.fillCredential(
        access: access.access, cipherID: id, context: context)
      XCTAssertEqual(credential.password, "fixture-write-second")
      do {
        _ = try await backend.createLogin(
          access: access.access, context: context,
          input: NativeBitwardenWriteInput(
            username: "fixture-write-user", password: "fixture-write-third", name: "fixture-name"))
        XCTFail("Write allowed after writable snapshot rejection")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      await backend.discard(sessionID: session.id)
    }

    func testOwnedBackendWritesAndDelayedLock() async throws {
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_CIPHER_WRITE_FIXTURE"])
      let fixture = try JSONDecoder().decode(
        CipherWriteFixture.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
      let endpoint = try XCTUnwrap(URL(string: fixture.endpoint))
      guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path.isEmpty, endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else { return XCTFail("Invalid owned endpoint") }
      let configuration = BitwardenServerConfiguration(
        region: .custom, customBaseURL: "https://fixture.example")
      let backend = NativeBitwardenSDKBackend { provider, settings in
        Client(
          tokenProvider: provider,
          settings: ClientSettings(
            identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
            userAgent: settings.userAgent, deviceType: .sdk,
            deviceIdentifier: settings.deviceIdentifier,
            bitwardenClientVersion: settings.bitwardenClientVersion,
            bitwardenPackageType: settings.bitwardenPackageType),
          managedSettings: ManagedSettingsBindingClient())
      }
      guard await backend.isAvailable else { return XCTFail("Fixture host guard rejected test") }
      let device = UUID()
      let result = try await backend.login(
        server: configuration, email: fixture.email,
        password: fixture.currentPassword, deviceID: device, secondFactor: nil)
      guard case .authenticated(let candidate) = result else {
        return XCTFail("Synthetic login failed")
      }
      let session = try await backend.initializeCrypto(
        candidateID: candidate.id, password: fixture.currentPassword)
      let recovery = try await backend.recoveryContext(sessionID: session.id)
      let endpoints = try configuration.endpoints()
      let record = try PasswordSessionRecoveryRecord(
        binding: PasswordAuthenticationBinding(
          profileID: UUID(), vaultID: UUID(),
          accountID: session.accountID, authority: endpoints.credentialAuthority),
        identityURL: endpoints.identityURL, apiURL: endpoints.apiURL,
        serviceID: endpoints.stableServiceID,
        deviceID: device, clientID: NativeBitwardenLoginRequestMetadata.clientID,
        email: recovery.email,
        sdkRevision: "synthetic", kdf: recovery.kdf,
        wrappedAccountState: recovery.wrappedAccountState,
        masterPasswordUnlockData: recovery.masterPasswordUnlockData, credential: session.credential,
        revision: 0, state: .ready)
      _ = await backend.lock(sessionID: session.id)
      await backend.discard(sessionID: session.id)
      let restored = try await backend.restoreLocked(record: record, server: configuration)
      let unlocked = try await backend.unlockRestored(
        sessionID: restored, record: record, password: fixture.currentPassword)
      unlocked.tokenProvider.publish(unlocked.credential.accessToken)
      let snapshot = try await backend.syncVault(sessionID: restored)
      let id = try XCTUnwrap(snapshot.logins.first?.id)
      let context = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
        origin: PasswordFillOrigin("https://fixture.example")!)
      let input = NativeBitwardenWriteInput(
        username: "fixture-write-user", password: "fixture-write-third", name: "fixture-name")
      let revision = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-01-02T00:00:00Z"))
      let first = try await backend.fillSnapshot(sessionID: restored)
      do {
        _ = try await backend.updateLogin(
          access: first.access, context: context, cipherID: id,
          revision: revision, input: input)
        XCTFail("Product update was not blocked")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .sdkUpdateUnavailable) }
      do {
        _ = try await backend.updateLoginFixture(
          access: first.access, context: context, cipherID: id,
          revision: revision.addingTimeInterval(-1), input: input)
        XCTFail("Stale revision accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleRevision) }
      let edited = try await backend.updateLoginFixture(
        access: first.access, context: context,
        cipherID: id, revision: revision, input: input)
      XCTAssertEqual(edited.cipherID, id)
      do {
        _ = try await backend.fillSnapshot(sessionID: restored)
        XCTFail("Old snapshot retained")
      } catch {}
      let resynced = try await backend.syncVault(sessionID: restored)
      XCTAssertEqual(resynced.logins.first?.name, "fixture-name")
      let second = try await backend.fillSnapshot(sessionID: restored)
      let credential = try await backend.fillCredential(
        access: second.access, cipherID: id, context: context)
      XCTAssertEqual(credential.password, "fixture-write-third")

      // The local control endpoints only synchronize the synthetic server's delayed response.
      let controlConfiguration = URLSessionConfiguration.ephemeral
      controlConfiguration.timeoutIntervalForRequest = 0.5
      controlConfiguration.timeoutIntervalForResource = 1.5
      let control = URLSession(configuration: controlConfiguration)
      defer { control.invalidateAndCancel() }
      let delayed = Task {
        try await backend.updateLoginFixture(
          access: second.access, context: context,
          cipherID: id, revision: edited.revision, input: input)
      }
      var observed = false
      for _ in 0..<40 {
        let (data, _) = try await control.data(
          from: URL(string: fixture.endpoint + "/fixture/status")!)
        if data == Data("ready".utf8) {
          observed = true
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      XCTAssertTrue(observed)
      _ = await backend.lock(sessionID: restored)
      do {
        _ = try await backend.unlockRestored(
          sessionID: restored, record: record, password: fixture.currentPassword)
        XCTFail("Unlock crossed active SDK write")
      } catch {}
      do {
        _ = try await backend.syncVault(sessionID: restored)
        XCTFail("Sync crossed active SDK write")
      } catch {}
      _ = try await control.data(from: URL(string: fixture.endpoint + "/fixture/release")!)
      do {
        _ = try await delayed.value
        XCTFail("Locked write reported confirmed")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .unconfirmed) }
      let renewed = try await backend.unlockRestored(
        sessionID: restored, record: record, password: fixture.currentPassword)
      renewed.tokenProvider.publish(renewed.credential.accessToken)
      _ = try await backend.syncVault(sessionID: restored)
      let current = try await backend.fillSnapshot(sessionID: restored)
      let created = try await backend.createLogin(
        access: current.access, context: context, input: input)
      XCTAssertNotEqual(created.cipherID, id)
      do {
        _ = try await backend.fillSnapshot(sessionID: restored)
        XCTFail("Snapshot retained after create")
      } catch {}
      await backend.discard(sessionID: restored)
    }

    func testOwnedSDKCipherCreateEditAndFailures() async throws {
      guard await NativeBitwardenSDKBackend().isAvailable else {
        XCTFail("Fixture host guard rejected test process")
        return
      }
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_CIPHER_WRITE_FIXTURE"])
      let fixture = try JSONDecoder().decode(
        CipherWriteFixture.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
      let endpoint = try XCTUnwrap(URL(string: fixture.endpoint))
      guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path.isEmpty, endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else {
        XCTFail("Invalid owned endpoint")
        return
      }

      NativeBitwardenLogging.bootstrap()
      let provider = NativeBitwardenTokenProvider()
      provider.publish("synthetic-owned-token")
      let client = Client(
        tokenProvider: provider,
        settings: ClientSettings(
          identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
          userAgent: "Arcusis fixture", deviceType: .sdk, deviceIdentifier: UUID().uuidString,
          bitwardenClientVersion: "0.1.0", bitwardenPackageType: "desktop"),
        managedSettings: ManagedSettingsBindingClient())
      let bridge = NativeBitwardenStateBridge()
      client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
      let repository = NativeBitwardenCipherRepository()
      try repository.acceptSnapshot([])
      client.platform().state().registerClientManagedRepositories(
        repositories: Repositories(
          cipher: repository, folder: nil, localUserDataKeyState: nil, organizationSharedKey: nil,
          send: nil, policy: nil, organization: nil))
      let kdf = Kdf.pbkdf2(iterations: fixture.iterations)
      try await client.crypto().initializeUserCrypto(
        req: InitUserCryptoRequest(
          userId: fixture.userID, kdfParams: kdf, email: fixture.email,
          accountCryptographicState: .v1(privateKey: fixture.privateKey),
          method: .masterPasswordUnlock(
            password: fixture.currentPassword,
            masterPasswordUnlock: MasterPasswordUnlockData(
              kdf: kdf, masterKeyWrappedUserKey: fixture.wrappedUserKey,
              salt: fixture.email, containedKeyId: nil)), upgradeToken: nil))
      defer {
        repository.revoke()
        client.crypto().clearUserCryptoKeys()
        provider.clear()
      }

      func login(_ password: String) -> LoginView {
        LoginView(
          username: "fixture-write-user", password: password, passwordRevisionDate: nil,
          uris: [
            LoginUriView(uri: "https://fixture.example/login", match: .host, uriChecksum: nil)
          ],
          totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil)
      }
      let ciphers = client.vault().ciphers()
      let created = try await ciphers.create(
        request: CipherCreateRequest(
          organizationId: nil, collectionIds: [], folderId: nil, name: "fixture-name",
          notes: "fixture-notes", favorite: true, reprompt: .none,
          type: .login(login("fixture-write-first")),
          fields: [
            FieldView(
              name: "fixture-custom", value: "fixture-custom-value", type: .text, linkedId: nil)
          ],
          archivedDate: nil))
      let id = try XCTUnwrap(created.id)
      XCTAssertEqual(created.name, "fixture-name")
      XCTAssertEqual(created.notes, "fixture-notes")
      XCTAssertTrue(created.favorite)
      XCTAssertEqual(created.fields?.first?.name, "fixture-custom")
      XCTAssertEqual(created.fields?.first?.value, "fixture-custom-value")
      XCTAssertEqual(created.login?.username, "fixture-write-user")
      XCTAssertEqual(created.login?.password, "fixture-write-first")
      XCTAssertEqual(created.login?.uris?.first?.uri, "https://fixture.example/login")
      let storedCreated = try await repository.get(id: id)
      XCTAssertNotNil(storedCreated)

      func edit(_ revision: Date, _ password: String) -> CipherEditRequest {
        CipherEditRequest(
          id: id, organizationId: created.organizationId, folderId: created.folderId,
          favorite: created.favorite, reprompt: created.reprompt, name: created.name,
          notes: created.notes, fields: created.fields ?? [], type: .login(login(password)),
          revisionDate: revision, archivedDate: created.archivedDate,
          attachments: created.attachments ?? [], key: created.key)
      }
      let updated = try await ciphers.edit(
        request: edit(created.revisionDate, "fixture-write-second"))
      XCTAssertEqual(updated.id, id)
      XCTAssertEqual(updated.name, created.name)
      XCTAssertEqual(updated.notes, created.notes)
      XCTAssertEqual(updated.favorite, created.favorite)
      XCTAssertEqual(updated.login?.username, "fixture-write-user")
      XCTAssertEqual(updated.login?.password, "fixture-write-second")
      XCTAssertEqual(updated.login?.uris?.first?.uri, "https://fixture.example/login")
      XCTAssertEqual(updated.login?.uris?.first?.match, .host)
      XCTAssertEqual(updated.fields, created.fields)
      let storedUpdated = try await repository.get(id: id)
      let encrypted = try XCTUnwrap(storedUpdated)
      let roundTrip = try await ciphers.decrypt(cipher: encrypted)
      XCTAssertEqual(roundTrip.login?.password, "fixture-write-second")
      XCTAssertEqual(roundTrip.fields?.first?.value, "fixture-custom-value")

      for revision in [
        created.revisionDate, updated.revisionDate, updated.revisionDate, updated.revisionDate,
      ] {
        do {
          _ = try await ciphers.edit(request: edit(revision, "fixture-write-third"))
          XCTFail("Rejected edit unexpectedly succeeded")
        } catch {}
      }
      let storedAfterFailures = try await repository.get(id: id)
      let afterFailures = try XCTUnwrap(storedAfterFailures)
      let unchanged = try await ciphers.decrypt(cipher: afterFailures)
      XCTAssertEqual(unchanged.login?.password, "fixture-write-second")
      _ = await bridge.clearTransientKeyState()
    }
  }
#endif
