#if ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK && ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE && canImport(ArcusisBitwardenSDK)
  import ArcusisBitwardenSDK
  import BrowserCore
  import Foundation
  import XCTest

  @testable import ArcusisBrowser

  private struct StrictBackendFixture: Decodable, Sendable {
    let endpoint: String
    let email: String
    let currentPassword: String
    let cipherID: UUID
  }

  private func optional(_ value: Any?) -> Any { value ?? NSNull() }

  private func control(_ endpoint: URL, path: String, body: Data? = nil) async throws -> Data {
    var request = URLRequest(url: endpoint.appendingPathComponent(path))
    request.httpMethod = body == nil ? "GET" : "POST"
    request.timeoutInterval = 4
    request.httpBody = body
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.connectionProxyDictionary = [
      "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
      "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
    ]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw NativeBitwardenWriteError.staleAccess
    }
    return data
  }

  private func seed(_ client: Client, endpoint: URL, cipherID: UUID) async throws {
    let attachment = AttachmentView(
      id: "attachment-a", url: "https://files.invalid/synthetic", size: "123",
      sizeName: "123 bytes", fileName: "synthetic-attachment.txt",
      key: Data(repeating: 7, count: 64).base64EncodedString())
    let view = CipherView(
      id: cipherID.uuidString.lowercased(), organizationId: nil, folderId: nil,
      collectionIds: [], key: nil, name: "synthetic-title", notes: "synthetic-note", type: .login,
      login: LoginView(
        username: "synthetic-old-user", password: "synthetic-old-password",
        passwordRevisionDate: nil,
        uris: [LoginUriView(uri: "https://fixture.example/login", match: .host, uriChecksum: nil)],
        totp: "synthetic-totp", autofillOnPageLoad: nil, fido2Credentials: nil),
      identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
      driversLicense: nil, passport: nil, favorite: true, reprompt: .none,
      organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true,
      localData: nil, attachments: [attachment], attachmentDecryptionFailures: nil,
      fields: [
        FieldView(name: "synthetic-field", value: "synthetic-value", type: .text, linkedId: nil)
      ],
      passwordHistory: nil, creationDate: Date(timeIntervalSince1970: 1_704_067_200),
      deletedDate: nil,
      revisionDate: Date(timeIntervalSince1970: 1_735_689_600), archivedDate: nil, partial: false)
    let cipher = try await client.vault().ciphers().encrypt(cipherView: view).cipher
    let login = try XCTUnwrap(cipher.login)
    let part = try XCTUnwrap(cipher.attachments?.first)
    let uri = try XCTUnwrap(login.uris?.first)
    let field = try XCTUnwrap(cipher.fields?.first)
    let body: [String: Any] = [
      "id": cipherID.uuidString.lowercased(), "key": optional(cipher.key),
      "name": optional(cipher.name), "notes": optional(cipher.notes),
      "login": [
        "username": optional(login.username), "password": optional(login.password),
        "uris": [["uri": optional(uri.uri), "match": 1, "uriChecksum": optional(uri.uriChecksum)]],
        "totp": optional(login.totp), "passwordRevisionDate": NSNull(),
        "autofillOnPageLoad": NSNull(), "fido2Credentials": NSNull(),
      ],
      "fields": [
        [
          "name": optional(field.name), "value": optional(field.value), "type": 0,
          "linkedId": NSNull(),
        ]
      ],
      "attachments": [
        [
          "object": "attachment", "id": optional(part.id), "url": optional(part.url),
          "size": optional(part.size), "sizeName": optional(part.sizeName),
          "fileName": optional(part.fileName), "key": optional(part.key),
        ]
      ],
    ]
    _ = try await control(
      endpoint, path: "fixture/seed", body: JSONSerialization.data(withJSONObject: body))
  }

  final class NativeBitwardenStrictBackendTests: XCTestCase {
    func testStrictPreparationLifecycle() async throws {
      let encoded = try XCTUnwrap(
        ProcessInfo.processInfo.environment["ARCUSIS_STRICT_BACKEND_FIXTURE"])
      let fixture = try JSONDecoder().decode(
        StrictBackendFixture.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
      let endpoint = try XCTUnwrap(URL(string: fixture.endpoint))
      guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
        endpoint.path.isEmpty, endpoint.user == nil, endpoint.password == nil,
        endpoint.query == nil, endpoint.fragment == nil
      else { return XCTFail("Invalid owned endpoint") }
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
      guard await backend.isAvailable else { return XCTFail("Fixture host rejected") }
      let server = BitwardenServerConfiguration(
        region: .custom, customBaseURL: "https://fixture.example")
      let login = try await backend.login(
        server: server, email: fixture.email, password: fixture.currentPassword,
        deviceID: UUID(), secondFactor: nil)
      guard case .authenticated(let candidate) = login else { return XCTFail("Login rejected") }
      let session = try await backend.initializeCrypto(
        candidateID: candidate.id, password: fixture.currentPassword)
      session.tokenProvider.publish(session.credential.accessToken)
      let maybeClient = await backend.strictClientForFixture(sessionID: session.id)
      let fixtureClient = try XCTUnwrap(maybeClient)
      try await seed(fixtureClient, endpoint: endpoint, cipherID: fixture.cipherID)
      _ = try await backend.syncVault(sessionID: session.id)
      print("strict-stage: first-sync")
      let access = try await backend.fillSnapshot(sessionID: session.id).access
      let context = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
        origin: try XCTUnwrap(PasswordFillOrigin("https://fixture.example")))
      let input = NativeBitwardenStrictUpdateInput(
        username: "synthetic-new-user", password: "synthetic-new-pass")
      do {
        _ = try await backend.prepareStrictUpdate(
          access: access, context: context, cipherID: UUID())
        XCTFail("Unknown cipher accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenFillError, .cipherUnavailable) }
      let wrongContext = PasswordFillContext(
        requestID: UUID(), binding: context.binding, origin: context.origin)
      let wrong = try await backend.prepareStrictUpdate(
        access: access, context: context, cipherID: fixture.cipherID)
      do {
        try await backend.strictUpdate(
          access: access, context: wrongContext, handle: wrong, input: input)
        XCTFail("Changed context accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let invalid = try await backend.prepareStrictUpdate(
        access: access, context: context, cipherID: fixture.cipherID)
      do {
        try await backend.strictUpdate(
          access: access, context: context, handle: invalid,
          input: NativeBitwardenStrictUpdateInput(username: nil, password: ""))
        XCTFail("Empty password accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .invalidInput) }
      do {
        try await backend.strictUpdate(
          access: access, context: context, handle: invalid, input: input)
        XCTFail("Invalid input retained handle")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let noToken = try await backend.prepareStrictUpdate(
        access: access, context: context, cipherID: fixture.cipherID)
      session.tokenProvider.clear()
      do {
        try await backend.strictUpdate(
          access: access, context: context, handle: noToken, input: input)
        XCTFail("Missing token accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      session.tokenProvider.publish(session.credential.accessToken)
      print("strict-stage: preflight")
      let handle = try await backend.prepareStrictUpdate(
        access: access, context: context, cipherID: fixture.cipherID)
      let foreign = NativeBitwardenSDKBackend()
      do {
        try await foreign.strictUpdate(
          access: access, context: context, handle: handle, input: input)
        XCTFail("Foreign client accepted handle")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      await backend.cancelStrictUpdate(sessionID: session.id, handle: handle)
      do {
        try await backend.strictUpdate(
          access: access, context: context, handle: handle, input: input)
        XCTFail("Cancelled handle accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let stale = try await backend.prepareStrictUpdate(
        access: access, context: context, cipherID: fixture.cipherID)
      _ = try await backend.syncVault(sessionID: session.id)
      print("strict-stage: replacement-sync")
      do {
        try await backend.strictUpdate(
          access: access, context: context, handle: stale, input: input)
        XCTFail("Replaced snapshot accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let latest = try await backend.fillSnapshot(sessionID: session.id).access
      let final = try await backend.prepareStrictUpdate(
        access: latest, context: context, cipherID: fixture.cipherID)
      let pending = Task {
        try await backend.strictUpdate(
          access: latest, context: context, handle: final, input: input)
      }
      var dispatched = false
      for _ in 0..<100 {
        if String(data: try await control(endpoint, path: "fixture/status"), encoding: .utf8)
          == "ready"
        {
          dispatched = true
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertTrue(dispatched)
      do {
        _ = try await backend.syncVault(sessionID: session.id)
        XCTFail("Sync overlapped pending write")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .operationInProgress) }
      pending.cancel()
      await backend.cancelStrictUpdate(sessionID: session.id, handle: final)
      _ = try await control(endpoint, path: "fixture/release")
      do {
        try await pending.value
        XCTFail("Dispatched update reported confirmation")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .unconfirmed) }
      print("strict-stage: unconfirmed")
      do {
        try await backend.strictUpdate(
          access: latest, context: context, handle: final, input: input)
        XCTFail("Consumed handle accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      _ = try await backend.syncVault(sessionID: session.id)
      print("strict-stage: reconciliation-sync")
      let fresh = try await backend.fillSnapshot(sessionID: session.id).access
      let updated = try await backend.fillCredential(
        access: fresh, cipherID: fixture.cipherID, context: context)
      XCTAssertEqual(updated.username, "synthetic-new-user")
      XCTAssertEqual(updated.password, "synthetic-new-pass")
      print("strict-stage: credential")
      _ = try await backend.prepareStrictUpdate(
        access: fresh, context: context, cipherID: fixture.cipherID)
      _ = await backend.lock(sessionID: session.id)
      do {
        _ = try await backend.prepareStrictUpdate(
          access: fresh, context: context, cipherID: fixture.cipherID)
        XCTFail("Locked session accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      await backend.discard(sessionID: session.id)
      print("strict-stage: complete")
    }
  }
#endif
