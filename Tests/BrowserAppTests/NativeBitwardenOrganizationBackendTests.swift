import BrowserCore
import Foundation
import XCTest

@testable import ArcusisBrowser

#if canImport(ArcusisBitwardenSDK) && ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE
  import ArcusisBitwardenSDK

  private struct OrganizationFixture: Decodable {
    let email: String
    let userID: String
    let currentPassword: String
    let privateKey: String
    let wrappedUserKey: String
    let iterations: UInt32
    let org: String
    let key: String
    let endpoint: String
  }

  final class NativeBitwardenOrganizationBackendTests: XCTestCase {
    func testSyntheticOrganizationBackend() async throws {
      guard ProcessInfo.processInfo.environment["ARCUSIS_ORG_BACKEND_TEST"] == "1" else {
        throw XCTSkip("Explicit synthetic organization fixture required")
      }
      guard let encoded = ProcessInfo.processInfo.environment["ARCUSIS_ORG_BACKEND_FIXTURE"],
        let data = Data(base64Encoded: encoded)
      else { throw NSError(domain: "SyntheticFixtureMissing", code: 1) }
      let fixture = try JSONDecoder().decode(OrganizationFixture.self, from: data)
      guard let endpoint = URL(string: fixture.endpoint), endpoint.scheme == "http",
        endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path == "", endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else {
        XCTFail("Invalid owned fixture endpoint")
        return
      }

      NativeBitwardenLogging.bootstrap()
      let preparation = Client(
        tokenProvider: NativeBitwardenTokenProvider(), settings: nil,
        managedSettings: ManagedSettingsBindingClient())
      preparation.kmStateBridge().registerBridgeImpl(bridgeImpl: NativeBitwardenStateBridge())
      let kdf = Kdf.pbkdf2(iterations: fixture.iterations)
      try await preparation.crypto().initializeUserCrypto(
        req: InitUserCryptoRequest(
          userId: fixture.userID, kdfParams: kdf, email: fixture.email,
          accountCryptographicState: .v1(privateKey: fixture.privateKey),
          method: .masterPasswordUnlock(
            password: fixture.currentPassword,
            masterPasswordUnlock: MasterPasswordUnlockData(
              kdf: kdf, masterKeyWrappedUserKey: fixture.wrappedUserKey,
              salt: fixture.email, containedKeyId: nil)), upgradeToken: nil))
      try await preparation.crypto().initializeOrgCrypto(
        req: InitOrgCryptoRequest(organizationKeys: [fixture.org: fixture.key]))
      let date = Date(timeIntervalSince1970: 0)
      let view = CipherView(
        id: nil, organizationId: fixture.org, folderId: nil, collectionIds: [], key: nil,
        name: "fixture-name", notes: nil, type: .login,
        login: LoginView(
          username: "fixture-user", password: "fixture-password", passwordRevisionDate: nil,
          uris: [LoginUriView(uri: "https://fixture.example", match: .host, uriChecksum: nil)],
          totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil),
        identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
        driversLicense: nil, passport: nil, favorite: false, reprompt: .none,
        organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true,
        localData: nil, attachments: nil, attachmentDecryptionFailures: nil, fields: nil,
        passwordHistory: nil, creationDate: date, deletedDate: nil, revisionDate: date,
        archivedDate: nil, partial: false)
      let cipher = try await preparation.vault().ciphers().encrypt(cipherView: view).cipher
      let preparedView = try await preparation.vault().ciphers().decrypt(cipher: cipher)
      XCTAssertTrue(preparedView.login?.uris?.first?.uri == "https://fixture.example")
      XCTAssertTrue(preparedView.login?.uris?.first?.match == .host)
      XCTAssertNotNil(cipher.login?.uris, "Encrypted URI absent from login")
      preparation.crypto().clearUserCryptoKeys()
      let cipherID = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
      var serialized: [String: Any] = [
        "object": "cipher", "id": cipherID.uuidString.lowercased(),
        "organizationId": fixture.org, "type": cipher.type.rawValue,
        "creationDate": "1970-01-01T00:00:00Z", "revisionDate": "1970-01-01T00:00:00Z",
        "favorite": cipher.favorite, "organizationUseTotp": cipher.organizationUseTotp,
        "edit": cipher.edit, "viewPassword": cipher.viewPassword,
      ]
      serialized["name"] = cipher.name
      serialized["key"] = cipher.key
      serialized["data"] = cipher.data
      if let login = cipher.login {
        var value: [String: Any] = [:]
        value["username"] = login.username
        value["password"] = login.password
        value["uris"] = login.uris?.map { uri in
          var value: [String: Any] = ["match": 1]
          value["uri"] = uri.uri
          value["uriChecksum"] = uri.uriChecksum
          return value
        }
        serialized["login"] = value
      }
      try await control(endpoint, ["cipher": serialized, "mode": "success"])

      let backend = NativeBitwardenSDKBackend { provider, settings in
        let local = ClientSettings(
          identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
          userAgent: settings.userAgent, deviceType: .sdk,
          deviceIdentifier: settings.deviceIdentifier,
          bitwardenClientVersion: settings.bitwardenClientVersion,
          bitwardenPackageType: settings.bitwardenPackageType)
        return Client(
          tokenProvider: provider, settings: local,
          managedSettings: ManagedSettingsBindingClient())
      }
      do {
        _ = try await backend.login(
          server: BitwardenServerConfiguration(region: .custom, customBaseURL: fixture.endpoint),
          email: fixture.email, password: fixture.currentPassword, deviceID: UUID(),
          secondFactor: nil)
        XCTFail("HTTP server configuration accepted")
      } catch {
        XCTAssertEqual(error as? BitwardenServerConfigurationError, .invalidCustomURL)
      }
      let result = try await backend.login(
        server: BitwardenServerConfiguration(
          region: .custom, customBaseURL: "https://fixture.example"),
        email: fixture.email, password: fixture.currentPassword, deviceID: UUID(), secondFactor: nil
      )
      guard case .authenticated(let candidate) = result else {
        XCTFail("Login failed")
        return
      }
      let session = try await backend.initializeCrypto(
        candidateID: candidate.id, password: fixture.currentPassword)
      session.tokenProvider.publish(session.credential.accessToken)
      let context = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
        origin: PasswordFillOrigin("https://fixture.example")!)
      func syncAndAccess() async throws -> NativeBitwardenFillAccess {
        let snapshot = try await backend.syncVault(sessionID: session.id)
        XCTAssertEqual(snapshot.logins.count, 1)
        XCTAssertEqual(snapshot.logins.first?.organizationID, UUID(uuidString: fixture.org))
        XCTAssertEqual(snapshot.logins.first?.uris.count, 1)
        XCTAssertTrue(snapshot.logins.first?.uris.first?.uri == "https://fixture.example")
        let access = try await backend.fillSnapshot(sessionID: session.id).access
        let credential = try await backend.fillCredential(
          access: access, cipherID: cipherID, context: context)
        XCTAssertTrue(
          credential.username == "fixture-user" && credential.password == "fixture-password")
        return access
      }
      func stale(_ access: NativeBitwardenFillAccess) async {
        do {
          _ = try await backend.fillCredential(access: access, cipherID: cipherID, context: context)
          XCTFail("Stale access was accepted")
        } catch { XCTAssertEqual(error as? NativeBitwardenFillError, .staleAccess) }
      }
      for mode in ["malformed", "failed", "unrelated"] {
        try await control(endpoint, ["mode": "success"])
        let access = try await syncAndAccess()
        try await control(endpoint, ["mode": mode])
        do {
          _ = try await backend.syncVault(sessionID: session.id)
          XCTFail("Invalid sync accepted")
        } catch {}
        await stale(access)
      }
      try await control(endpoint, ["mode": "success"])
      let beforeEmpty = try await syncAndAccess()
      try await control(endpoint, ["mode": "empty"])
      let empty = try await backend.syncVault(sessionID: session.id)
      XCTAssertTrue(empty.logins.isEmpty)
      await stale(beforeEmpty)
      let emptyAccess = try await backend.fillSnapshot(sessionID: session.id).access
      do {
        _ = try await backend.fillCredential(
          access: emptyAccess, cipherID: cipherID, context: context)
        XCTFail("Empty sync retained cipher")
      } catch { XCTAssertEqual(error as? NativeBitwardenFillError, .cipherUnavailable) }
      try await control(endpoint, ["mode": "missing"])
      do {
        _ = try await backend.syncVault(sessionID: session.id)
        XCTFail("Cipher without current organization membership accepted")
      } catch {}
      await stale(emptyAccess)
      try await control(endpoint, ["mode": "success"])
      let beforeLock = try await syncAndAccess()
      let locked = await backend.lock(sessionID: session.id)
      XCTAssertTrue(locked)
      await stale(beforeLock)
      await backend.discard(sessionID: session.id)
      await stale(beforeLock)

      let secondResult = try await backend.login(
        server: BitwardenServerConfiguration(
          region: .custom, customBaseURL: "https://fixture.example"),
        email: fixture.email, password: fixture.currentPassword, deviceID: UUID(), secondFactor: nil
      )
      guard case .authenticated(let secondCandidate) = secondResult else {
        XCTFail("Second login failed")
        return
      }
      let second = try await backend.initializeCrypto(
        candidateID: secondCandidate.id, password: fixture.currentPassword)
      second.tokenProvider.publish(second.credential.accessToken)
      _ = try await backend.syncVault(sessionID: second.id)
      let beforeDiscard = try await backend.fillSnapshot(sessionID: second.id).access
      _ = try await backend.fillCredential(
        access: beforeDiscard, cipherID: cipherID, context: context)
      await backend.discard(sessionID: second.id)
      await stale(beforeDiscard)
    }

    private func control(_ endpoint: URL, _ object: [String: Any]) async throws {
      var request = URLRequest(url: endpoint.appendingPathComponent("control"))
      request.httpMethod = "POST"
      request.httpBody = try JSONSerialization.data(withJSONObject: object)
      let (_, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NSError(domain: "SyntheticFixture", code: 1)
      }
    }
  }
#endif
