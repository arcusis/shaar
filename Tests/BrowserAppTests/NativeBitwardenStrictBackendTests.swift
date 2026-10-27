import BrowserCore
import Foundation
import XCTest

@testable import ArcusisBrowser

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

  private actor StrictPreflightBarrier {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
      entered = true
      enteredWaiter?.resume()
      enteredWaiter = nil
      if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }

    func waitUntilEntered() async {
      if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }

    func release() {
      released = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }

  private func adopt(
    _ backend: NativeBitwardenSDKBackend, authority: NativeBitwardenWriteAuthority,
    session: NativeBitwardenEstablishedSession, access: NativeBitwardenFillAccess,
    profileID: UUID, server: BitwardenServerConfiguration
  ) async throws -> NativeBitwardenWriteAuthority.Lease {
    let endpoints = try server.endpoints()
    let binding = NativeBitwardenWriteAuthority.Binding(
      owner: PasswordAuthenticationBinding(
        profileID: profileID, vaultID: UUID(), accountID: session.accountID,
        authority: endpoints.credentialAuthority),
      identityURL: endpoints.identityURL, apiURL: endpoints.apiURL, access: access)
    let lease = try XCTUnwrap(authority.adopt(ticket: authority.revoke(), binding: binding))
    let admission = try XCTUnwrap(
      nativeBitwardenFixtureAdmission(authority: authority, lease: lease))
    try await backend.adoptStrictWriteAuthority(admission)
    return lease
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
      var access = try await backend.fillSnapshot(sessionID: session.id).access
      let profileID = UUID()
      let authority = NativeBitwardenWriteAuthority()
      let context = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: profileID, tabID: UUID()),
        origin: try XCTUnwrap(PasswordFillOrigin("https://fixture.example")))
      let input = NativeBitwardenStrictUpdateInput(
        username: "synthetic-new-user", password: "synthetic-new-pass")
      do {
        _ = try await backend.prepareStrictUpdate(
          access: access, context: context, cipherID: fixture.cipherID)
        XCTFail("Unadopted snapshot accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let endpoints = try server.endpoints()
      let badOwner = PasswordAuthenticationBinding(
        profileID: profileID, vaultID: UUID(), accountID: UUID(),
        authority: endpoints.credentialAuthority)
      let correctOwner = PasswordAuthenticationBinding(
        profileID: profileID, vaultID: UUID(), accountID: session.accountID,
        authority: endpoints.credentialAuthority)
      let invalidBindings = [
        NativeBitwardenWriteAuthority.Binding(
          owner: badOwner, identityURL: endpoints.identityURL,
          apiURL: endpoints.apiURL, access: access),
        NativeBitwardenWriteAuthority.Binding(
          owner: correctOwner, identityURL: URL(string: "https://other.example")!,
          apiURL: endpoints.apiURL, access: access),
        NativeBitwardenWriteAuthority.Binding(
          owner: correctOwner, identityURL: endpoints.identityURL,
          apiURL: URL(string: "https://other.example")!, access: access),
        NativeBitwardenWriteAuthority.Binding(
          owner: PasswordAuthenticationBinding(
            profileID: profileID, vaultID: UUID(), accountID: session.accountID,
            authority: URL(string: "https://other.example")!), identityURL: endpoints.identityURL,
          apiURL: endpoints.apiURL, access: access),
      ]
      for binding in invalidBindings {
        let invalid = NativeBitwardenWriteAuthority()
        let lease = try XCTUnwrap(invalid.adopt(ticket: invalid.revoke(), binding: binding))
        let admission = try XCTUnwrap(
          nativeBitwardenFixtureAdmission(authority: invalid, lease: lease))
        do {
          try await backend.adoptStrictWriteAuthority(admission)
          XCTFail("Mismatched account or endpoint accepted")
        } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
        invalid.revoke()
      }
      let oldLease = try await adopt(
        backend, authority: authority, session: session,
        access: access, profileID: profileID, server: server)
      let pausedHandle = try await backend.prepareStrictUpdate(
        access: access, context: context, cipherID: fixture.cipherID)
      let barrier = StrictPreflightBarrier()
      let installed = await backend.setStrictPreflightForFixture { await barrier.pause() }
      XCTAssertTrue(installed)
      let pausedAccess = access
      let paused = Task {
        try await backend.strictUpdate(
          access: pausedAccess, context: context, handle: pausedHandle, input: input)
      }
      await barrier.waitUntilEntered()
      authority.revoke()
      await barrier.release()
      do {
        try await paused.value
        XCTFail("Revoked paused preflight dispatched")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let clearedHook = await backend.setStrictPreflightForFixture(nil)
      XCTAssertTrue(clearedHook)
      let countData = try await control(endpoint, path: "fixture/count")
      let counts = try JSONDecoder().decode([String: Int].self, from: countData)
      XCTAssertEqual(counts["put"], 0)
      XCTAssertEqual(counts["create"], 0)
      _ = try await backend.syncVault(sessionID: session.id)
      let oldAdmission = try XCTUnwrap(
        nativeBitwardenFixtureAdmission(authority: authority, lease: oldLease))
      do {
        try await backend.adoptStrictWriteAuthority(oldAdmission)
        XCTFail("Revoked adoption revived after sync")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      access = try await backend.fillSnapshot(sessionID: session.id).access
      _ = try await adopt(
        backend, authority: authority, session: session,
        access: access, profileID: profileID, server: server)
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
      _ = try await adopt(
        backend, authority: authority, session: session,
        access: latest, profileID: profileID, server: server)
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
      let freshLease = try await adopt(
        backend, authority: authority, session: session,
        access: fresh, profileID: profileID, server: server)
      let updated = try await backend.fillCredential(
        access: fresh, cipherID: fixture.cipherID, context: context)
      XCTAssertEqual(updated.username, "synthetic-new-user")
      XCTAssertEqual(updated.password, "synthetic-new-pass")
      print("strict-stage: credential")
      let preCreate = try await backend.prepareStrictUpdate(
        access: fresh, context: context, cipherID: fixture.cipherID)
      let otherProfile = UUID()
      let otherAuthority = NativeBitwardenWriteAuthority()
      let otherLogin = try await backend.login(
        server: server, email: fixture.email, password: fixture.currentPassword,
        deviceID: UUID(), secondFactor: nil)
      guard case .authenticated(let otherCandidate) = otherLogin else {
        return XCTFail("Second synthetic login rejected")
      }
      let otherSession = try await backend.initializeCrypto(
        candidateID: otherCandidate.id, password: fixture.currentPassword)
      otherSession.tokenProvider.publish(otherSession.credential.accessToken)
      _ = try await backend.syncVault(sessionID: otherSession.id)
      let otherAccess = try await backend.fillSnapshot(sessionID: otherSession.id).access
      let otherContext = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: otherProfile, tabID: UUID()),
        origin: try XCTUnwrap(PasswordFillOrigin("https://fixture.example")))
      _ = try await adopt(
        backend, authority: otherAuthority, session: otherSession,
        access: otherAccess, profileID: otherProfile, server: server)
      let otherPrepared = try await backend.prepareStrictUpdate(
        access: otherAccess, context: otherContext, cipherID: fixture.cipherID)
      authority.revoke()
      do {
        try await backend.strictUpdate(
          access: fresh, context: context, handle: preCreate, input: input)
        XCTFail("Revoked Profile retained dispatch authority")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      let independentData = try await control(endpoint, path: "fixture/count")
      let independentCounts = try JSONDecoder().decode([String: Int].self, from: independentData)
      XCTAssertEqual(independentCounts["put"], 1)
      XCTAssertEqual(independentCounts["create"], 0)
      let createInput = NativeBitwardenWriteInput(
        username: "synthetic-create-user", password: "synthetic-create-pass",
        name: "synthetic-create-name")
      let creating = Task {
        try await backend.createLogin(
          access: otherAccess, context: otherContext, input: createInput)
      }
      var createDispatched = false
      for _ in 0..<100 {
        if String(data: try await control(endpoint, path: "fixture/create-status"), encoding: .utf8)
          == "ready"
        {
          createDispatched = true
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertTrue(createDispatched)
      do {
        _ = try await backend.syncVault(sessionID: otherSession.id)
        XCTFail("Sync overlapped pending create")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .operationInProgress) }
      do {
        try await backend.strictUpdate(
          access: otherAccess, context: otherContext, handle: otherPrepared, input: input)
        XCTFail("Prepared update survived create dispatch")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      _ = try await control(endpoint, path: "fixture/create-release")
      do {
        _ = try await creating.value
        XCTFail("Create reported HTTP-only confirmation")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .unconfirmed) }
      let completedCreates = await backend.completedStrictCreatesForFixture()
      XCTAssertEqual(completedCreates, 1)
      let reconciled = try await backend.syncVault(sessionID: otherSession.id)
      let createdID = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
      XCTAssertTrue(
        reconciled.logins.contains { $0.id == createdID && $0.username == "synthetic-create-user" })
      let afterCreate = try await backend.fillSnapshot(sessionID: otherSession.id).access
      let otherLease = try await adopt(
        backend, authority: otherAuthority, session: otherSession,
        access: afterCreate, profileID: otherProfile, server: server)
      _ = try await backend.prepareStrictUpdate(
        access: afterCreate, context: otherContext, cipherID: fixture.cipherID)
      print("strict-stage: create-reconciled")
      _ = await backend.lock(sessionID: session.id)
      let lockedAdmission = try XCTUnwrap(
        nativeBitwardenFixtureAdmission(authority: authority, lease: freshLease))
      do {
        try await backend.adoptStrictWriteAuthority(lockedAdmission)
        XCTFail("Locked owner accepted stale adoption")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      XCTAssertTrue(otherAuthority.isCurrent(otherLease))
      do {
        _ = try await backend.prepareStrictUpdate(
          access: fresh, context: context, cipherID: fixture.cipherID)
        XCTFail("Locked session accepted")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess) }
      await backend.discard(sessionID: session.id)
      _ = await backend.lock(sessionID: otherSession.id)
      await backend.discard(sessionID: otherSession.id)
      print("strict-stage: complete")
    }
  }
#endif

#if !ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK
  final class NativeBitwardenStrictDefaultTests: XCTestCase {
    func testLegacyPathsRemainFailClosedWithoutSession() async throws {
      let id = UUID()
      var state = NativeBitwardenFillAccessState<Int>(sessionID: id)
      let ticket = try state.beginSync()
      try state.publish(ticket: ticket, snapshot: .empty, items: [:])
      state.finishSync(ticket)
      let access = try state.snapshot().access
      let context = PasswordFillContext(
        requestID: UUID(),
        binding: PasswordFillBinding(windowID: UUID(), profileID: UUID(), tabID: UUID()),
        origin: try XCTUnwrap(PasswordFillOrigin("https://fixture.example")))
      let backend = NativeBitwardenSDKBackend()
      let input = NativeBitwardenWriteInput(
        username: "synthetic-u", password: "synthetic-p", name: "synthetic-n")
      do {
        _ = try await backend.updateLogin(
          access: access, context: context, cipherID: UUID(),
          revision: Date(timeIntervalSince1970: 0), input: input)
        XCTFail("Legacy update unexpectedly available")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .sdkUpdateUnavailable) }
      do {
        _ = try await backend.prepareStrictUpdate(
          access: access, context: context, cipherID: UUID())
        XCTFail("Strict SDK unexpectedly available")
      } catch { XCTAssertEqual(error as? NativeBitwardenWriteError, .sdkUpdateUnavailable) }
      do {
        _ = try await backend.createLogin(access: access, context: context, input: input)
        XCTFail("Create accepted missing session")
      } catch {
        #if canImport(ArcusisBitwardenSDK)
          XCTAssertEqual(error as? NativeBitwardenWriteError, .staleAccess)
        #else
          XCTAssertEqual(error as? NativeBitwardenBackendError, .sdkUnavailable)
        #endif
      }
      do {
        _ = try await backend.fillSnapshot(sessionID: id)
        XCTFail("Read accepted missing session")
      } catch {
        #if canImport(ArcusisBitwardenSDK)
          XCTAssertEqual(error as? NativeBitwardenFillError, .staleAccess)
        #else
          XCTAssertEqual(error as? NativeBitwardenBackendError, .sdkUnavailable)
        #endif
      }
    }
  }
#endif
