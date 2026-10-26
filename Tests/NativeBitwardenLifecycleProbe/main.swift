import BitwardenFFI
import Foundation

private enum ProbeFailure: Error {
  case fixture
  case login
  case userCrypto
  case publication
  case sync
  case cipherDecrypt
  case lock
  case candidateCleanup
  case disconnect
  case cleanup
}

private let deviceID = "00000000-0000-4000-8000-000000000026"
private let cipherName = "native-vault-lifecycle-synthetic-cipher"
private let cipherUsername = "synthetic-vault-user"
private let cipherPassword = "synthetic-vault-password"
private let expectedAccessToken = "synthetic-lifecycle-access-token"
private let expectedRefreshToken = "synthetic-lifecycle-refresh-token"
private let preparedOutputMarker = "BITWARDEN_LIFECYCLE_PREPARED_V1:"
private let lifecycleCompletionMarker = "BITWARDEN_LIFECYCLE_COMPLETE_V1"
private let lifecycleStageMarker = "BITWARDEN_LIFECYCLE_STAGE_V1:"
@MainActor private var currentFailureStage = "startup"

@MainActor private func reportStage(_ stage: String) {
  currentFailureStage = String(stage.split(separator: "=", maxSplits: 1).first ?? "unknown")
  print("\(lifecycleStageMarker)\(stage)")
}

private func safeErrorType(_ error: Error) -> String {
  let typeName = String(reflecting: type(of: error))
  let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.")
  let name = String(typeName.unicodeScalars.filter { allowed.contains($0) }.prefix(80))
  return name.isEmpty ? "unknown_error" : name
}

private func kdf(_ iterations: UInt32) -> Kdf { .pbkdf2(iterations: iterations) }

private func makeSettings(endpoint: URL) -> ClientSettings {
  ClientSettings(
    identityUrl: endpoint.absoluteString + "identity",
    apiUrl: endpoint.absoluteString + "api",
    userAgent: "Arcusis native vault lifecycle probe",
    deviceType: .sdk,
    deviceIdentifier: deviceID,
    bitwardenClientVersion: "0.0.0-synthetic",
    bitwardenPackageType: "desktop")
}

private func initializedRequest(_ fixture: FixtureInput) -> InitUserCryptoRequest {
  let params = kdf(fixture.iterations)
  return InitUserCryptoRequest(
    userId: fixture.userID,
    kdfParams: params,
    email: fixture.email,
    accountCryptographicState: .v1(privateKey: fixture.privateKey),
    method: .masterPasswordUnlock(
      password: fixture.currentPassword,
      masterPasswordUnlock: MasterPasswordUnlockData(
        kdf: params,
        masterKeyWrappedUserKey: fixture.wrappedUserKey,
        salt: fixture.email,
        containedKeyId: nil)),
    upgradeToken: nil)
}

private func makeCipherView() -> CipherView {
  let date = Date(timeIntervalSince1970: 0)
  return CipherView(
    id: nil, organizationId: nil, folderId: nil, collectionIds: [], key: nil,
    name: cipherName, notes: nil, type: .login,
    login: LoginView(
      username: cipherUsername, password: cipherPassword,
      passwordRevisionDate: nil, uris: nil, totp: nil, autofillOnPageLoad: nil,
      fido2Credentials: nil),
    identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
    driversLicense: nil, passport: nil, favorite: false, reprompt: .none,
    organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true,
    localData: nil, attachments: nil, attachmentDecryptionFailures: nil,
    fields: nil, passwordHistory: nil, creationDate: date, deletedDate: nil,
    revisionDate: date, archivedDate: nil, partial: false)
}

private func encodedCipher(_ cipher: Cipher, id: String) throws -> [String: Any] {
  let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
  var result: [String: Any] = [
    "object": "cipher", "id": id, "type": cipher.type.rawValue,
    "creationDate": date, "revisionDate": date,
    "favorite": cipher.favorite, "organizationUseTotp": cipher.organizationUseTotp,
    "edit": cipher.edit, "viewPassword": cipher.viewPassword,
  ]
  if let name = cipher.name { result["name"] = name }
  if let notes = cipher.notes { result["notes"] = notes }
  if let key = cipher.key { result["key"] = key }
  if let data = cipher.data { result["data"] = data }
  if let login = cipher.login {
    var loginValue: [String: Any] = [:]
    if let username = login.username { loginValue["username"] = username }
    if let password = login.password { loginValue["password"] = password }
    if let totp = login.totp { loginValue["totp"] = totp }
    if let uris = login.uris { loginValue["uris"] = uris.map { ["uri": $0.uri as Any] } }
    result["login"] = loginValue
  }
  return result
}

private func prepare(_ fixture: FixtureInput) async throws {
  let provider = FencedTokenProvider()
  let bridge = NativeStateBridge()
  let client = Client(
    tokenProvider: provider, settings: nil,
    managedSettings: ManagedSettingsBindingClient())
  client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
  let crypto = client.crypto()
  try await crypto.initializeUserCrypto(req: initializedRequest(fixture))
  let encrypted = try await client.vault().ciphers().encrypt(cipherView: makeCipherView())
  let update = try await crypto.makeUpdatePassword(newPassword: fixture.newPassword)
  let cipher = try encodedCipher(
    encrypted.cipher, id: "00000000-0000-4000-8000-000000000103")
  let cipherBytes = try JSONSerialization.data(withJSONObject: cipher, options: [.sortedKeys])
  let value = PreparedFixture(
    passwordHash: update.passwordHash,
    newKey: update.newKey,
    encryptedCipherBase64: cipherBytes.base64EncodedString())
  let payload = try JSONEncoder().encode(value)
  guard payload.count <= 1_048_576 else { throw ProbeFailure.fixture }
  let frame = Data("\n\(preparedOutputMarker)".utf8) + payload + Data("\n".utf8)
  FileHandle.standardOutput.write(frame)
}

private func passwordLogin(
  client: Client, endpoint: URL, fixture: FixtureInput, password: String
) async throws -> LoginSuccessResponse {
  let auth = client.auth().login()
  let prelogin = try await auth.getPasswordPrelogin(email: fixture.email)
  guard prelogin.kdf == kdf(fixture.iterations), prelogin.salt == fixture.email else {
    throw ProbeFailure.login
  }
  let request = PasswordLoginRequest(
    loginRequest: LoginRequest(
      clientId: "arcusis-browser-synthetic-probe",
      device: LoginDeviceRequest(
        deviceType: .sdk,
        deviceIdentifier: deviceID,
        deviceName: "Synthetic Swift Probe",
        devicePushToken: nil)),
    email: fixture.email,
    password: password,
    preloginResponse: prelogin,
    twoFactor: nil)
  switch try await auth.loginViaPassword(request: request) {
  case .authenticated(let response):
    return response
  case .twoFactorRequired:
    throw ProbeFailure.login
  }
}

private func installLoginCrypto(
  client: Client, bridge: NativeStateBridge, fixture: FixtureInput, result: LoginSuccessResponse
) async throws {
  guard let wrapped = result.wrappedAccountCryptoState else {
    print("native_vault_crypto_input=wrapped_account_state_missing")
    throw ProbeFailure.userCrypto
  }
  guard let unlock = result.userDecryptionOptions.masterPasswordUnlock else {
    print("native_vault_crypto_input=password_unlock_missing")
    throw ProbeFailure.userCrypto
  }
  guard unlock.masterKeyWrappedUserKey == fixture.newKey,
    unlock.salt == fixture.email, unlock.kdf == kdf(fixture.iterations)
  else {
    print("native_vault_crypto_input=password_unlock_binding_mismatch")
    throw ProbeFailure.userCrypto
  }
  let request = InitUserCryptoRequest(
    userId: fixture.userID,
    kdfParams: kdf(fixture.iterations),
    email: fixture.email,
    accountCryptographicState: wrapped,
    method: .masterPasswordUnlock(
      password: fixture.newPassword,
      masterPasswordUnlock: unlock),
    upgradeToken: nil)
  do {
    try await client.crypto().initializeUserCrypto(req: request)
    let userKey = try await client.crypto().getUserEncryptionKey()
    await bridge.setUserKey(value: userKey)
  } catch {
    print("native_vault_sdk_error_type=\(safeErrorType(error))")
    throw ProbeFailure.userCrypto
  }
}

private func makeClient(
  endpoint: URL, provider: FencedTokenProvider, bridge: NativeStateBridge
) -> Client {
  let client = Client(
    tokenProvider: provider, settings: makeSettings(endpoint: endpoint),
    managedSettings: ManagedSettingsBindingClient())
  client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
  return client
}

private func makeBinding(profile: UUID, vault: UUID, account: UUID) -> PasswordAuthenticationBinding
{
  PasswordAuthenticationBinding(
    profileID: profile, vaultID: vault, accountID: account,
    authority: URL(string: "https://vault.lifecycle.invalid")!)
}

private func isLocked(_ client: Client) async -> Bool {
  do {
    _ = try await client.crypto().getUserEncryptionKey()
    return false
  } catch {
    return true
  }
}

private func decryptsSynthetic(_ client: Client, cipher: Cipher) async -> Bool {
  do {
    let decrypted = try await client.vault().ciphers().decrypt(cipher: cipher)
    return decrypted.name == cipherName
      && decrypted.login?.username == cipherUsername
      && decrypted.login?.password == cipherPassword
  } catch {
    return false
  }
}

private func waitForHeldLogin(endpoint: URL) async throws {
  let url = endpoint.appending(path: "probe/late-login-waiting")
  for _ in 0..<200 {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw ProbeFailure.login
    }
    if String(data: data, encoding: .ascii) == "waiting" { return }
    try await Task.sleep(for: .milliseconds(25))
  }
  throw ProbeFailure.login
}

private func releaseHeldLogin(endpoint: URL) async throws {
  var request = URLRequest(url: endpoint.appending(path: "probe/release-late-login"))
  request.httpMethod = "POST"
  let (_, response) = try await URLSession.shared.data(for: request)
  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
    throw ProbeFailure.login
  }
}

private func removeOwnedCredentials(
  _ store: PasswordCredentialStore, bindings: [PasswordAuthenticationBinding]
) throws {
  var failed = false
  for binding in bindings {
    do {
      try store.delete(for: binding)
    } catch {
      failed = true
    }
  }
  for binding in bindings {
    do {
      if try store.read(for: binding) != nil { failed = true }
    } catch {
      failed = true
    }
  }
  if failed { throw ProbeFailure.cleanup }
}

@MainActor
private func lateCommitCase(
  endpoint: URL, fixture: FixtureInput, store: PasswordCredentialStore,
  sharedVaultID: UUID, accountID: UUID, fetchedCipher: Cipher, disable: Bool
) async throws {
  let profile = UUID()
  let binding = makeBinding(profile: profile, vault: sharedVaultID, account: accountID)
  let provider = FencedTokenProvider()
  let bridge = NativeStateBridge()
  let client = makeClient(endpoint: endpoint, provider: provider, bridge: bridge)
  let gate = PasswordAuthenticationGate(binding: binding)
  do {
    guard let attempt = gate.beginAttempt() else { throw ProbeFailure.publication }
    let pendingLogin = Task {
      try await passwordLogin(
        client: client, endpoint: endpoint, fixture: fixture, password: fixture.newPassword)
    }
    try await waitForHeldLogin(endpoint: endpoint)
    if disable {
      gate.setEnabled(false)
    } else {
      gate.rebind(to: makeBinding(profile: UUID(), vault: sharedVaultID, account: accountID))
    }
    try await releaseHeldLogin(endpoint: endpoint)
    let response = try await pendingLogin.value
    try await installLoginCrypto(
      client: client, bridge: bridge, fixture: fixture, result: response)
    guard await bridge.hasTransientKeyState(),
      await decryptsSynthetic(client, cipher: fetchedCipher)
    else { throw ProbeFailure.userCrypto }

    var wroteCredential = false
    let committed = gate.commit(attempt) {
      do {
        try store.write(PasswordCredential(accessToken: response.accessToken), for: binding)
        provider.publish(response.accessToken)
        wroteCredential = true
      } catch {}
    }
    guard !committed, !wroteCredential, await provider.getAccessToken() == nil,
      try store.read(for: binding) == nil
    else { throw ProbeFailure.publication }
    if disable {
      reportStage("disabled_late_commit_rejected=passed")
    } else {
      reportStage("rebound_late_commit_rejected=passed")
    }

    client.crypto().clearUserCryptoKeys()
    let bridgeCleared = await bridge.clearTransientKeyState()
    guard bridgeCleared, await isLocked(client),
      !(await decryptsSynthetic(client, cipher: fetchedCipher))
    else { throw ProbeFailure.candidateCleanup }
    if disable {
      reportStage("disabled_candidate_keys_unusable=passed")
    } else {
      reportStage("rebound_candidate_keys_unusable=passed")
    }
    try removeOwnedCredentials(store, bindings: [binding])
    if disable {
      reportStage("disabled_candidate_record_removed=passed")
    } else {
      reportStage("rebound_candidate_record_removed=passed")
    }
  } catch {
    gate.setEnabled(false)
    provider.clear()
    client.crypto().clearUserCryptoKeys()
    let bridgeHadState = await bridge.hasTransientKeyState()
    let bridgeClearObserved = await bridge.clearTransientKeyState()
    try removeOwnedCredentials(store, bindings: [binding])
    guard !bridgeHadState || bridgeClearObserved, !(await bridge.hasTransientKeyState()) else {
      throw ProbeFailure.cleanup
    }
    throw error
  }
}

@MainActor
private func deniedStoreCase(
  endpoint: URL, fixture: FixtureInput, store: PasswordCredentialStore,
  sharedVaultID: UUID, accountID: UUID, fetchedCipher: Cipher,
  independentClient: Client, independentProvider: FencedTokenProvider,
  independentBinding: PasswordAuthenticationBinding
) async throws {
  let binding = makeBinding(profile: UUID(), vault: sharedVaultID, account: accountID)
  let deniedStore = PasswordCredentialStore(
    service: "com.arcusis.browser.password-credentials.probe-denied",
    storage: DeniedCredentialStorage())
  let provider = FencedTokenProvider()
  let bridge = NativeStateBridge()
  let client = makeClient(endpoint: endpoint, provider: provider, bridge: bridge)
  let gate = PasswordAuthenticationGate(binding: binding)
  do {
    guard let attempt = gate.beginAttempt() else { throw ProbeFailure.publication }
    let pendingLogin = Task {
      try await passwordLogin(
        client: client, endpoint: endpoint, fixture: fixture, password: fixture.newPassword)
    }
    try await waitForHeldLogin(endpoint: endpoint)
    try await releaseHeldLogin(endpoint: endpoint)
    let response = try await pendingLogin.value
    try await installLoginCrypto(
      client: client, bridge: bridge, fixture: fixture, result: response)
    guard await bridge.hasTransientKeyState(),
      await decryptsSynthetic(client, cipher: fetchedCipher)
    else { throw ProbeFailure.userCrypto }
    reportStage("denied_store_candidate_login_initialized=passed")

    var storageDenied = false
    let committed = gate.commit(attempt) {
      do {
        try deniedStore.write(PasswordCredential(accessToken: response.accessToken), for: binding)
        provider.publish(response.accessToken)
      } catch {
        storageDenied = true
      }
    }
    guard committed, storageDenied, await provider.getAccessToken() == nil,
      try deniedStore.read(for: binding) == nil
    else { throw ProbeFailure.publication }
    reportStage("denied_store_no_token_publication=passed")

    client.crypto().clearUserCryptoKeys()
    guard await bridge.clearTransientKeyState(), await isLocked(client),
      !(await bridge.hasTransientKeyState()),
      !(await decryptsSynthetic(client, cipher: fetchedCipher))
    else { throw ProbeFailure.candidateCleanup }
    reportStage("denied_store_candidate_keys_unusable=passed")
    guard await independentProvider.getAccessToken() == "synthetic-independent-context-token",
      try store.read(for: independentBinding)?.accessToken
        == "synthetic-independent-context-token",
      await decryptsSynthetic(independentClient, cipher: fetchedCipher)
    else { throw ProbeFailure.disconnect }
    reportStage("denied_store_independent_client_preserved=passed")
    try removeOwnedCredentials(deniedStore, bindings: [binding])
    reportStage("denied_store_candidate_record_absent=passed")
  } catch {
    gate.setEnabled(false)
    provider.clear()
    client.crypto().clearUserCryptoKeys()
    let bridgeHadState = await bridge.hasTransientKeyState()
    let bridgeClearObserved = await bridge.clearTransientKeyState()
    try removeOwnedCredentials(deniedStore, bindings: [binding])
    guard !bridgeHadState || bridgeClearObserved, !(await bridge.hasTransientKeyState()) else {
      throw ProbeFailure.cleanup
    }
    throw error
  }
}

@MainActor
private func lifecycle(_ fixture: FixtureInput, endpoint: URL) async throws {
  guard let passwordHash = fixture.passwordHash, !passwordHash.isEmpty,
    let newKey = fixture.newKey, !newKey.isEmpty,
    let cipherBase64 = fixture.encryptedCipherBase64,
    let cipherBytes = Data(base64Encoded: cipherBase64),
    let cipherJSON = try JSONSerialization.jsonObject(with: cipherBytes) as? [String: Any],
    let userID = cipherJSON["id"] as? String
  else { throw ProbeFailure.fixture }
  _ = passwordHash
  _ = newKey

  let namespace = PasswordCredentialProbeNamespace()
  let store = PasswordCredentialStore(probeNamespace: namespace)
  let sharedVaultID = UUID()
  let accountID = UUID()
  let activeBinding = makeBinding(profile: UUID(), vault: sharedVaultID, account: accountID)
  let independentBinding = makeBinding(profile: UUID(), vault: sharedVaultID, account: accountID)
  do {
    let independentProvider = FencedTokenProvider()
    independentProvider.publish("synthetic-independent-context-token")
    try store.write(
      PasswordCredential(accessToken: "synthetic-independent-context-token"),
      for: independentBinding)
    let independentBridge = NativeStateBridge()
    let independentClient = Client(
      tokenProvider: independentProvider, settings: nil,
      managedSettings: ManagedSettingsBindingClient())
    independentClient.kmStateBridge().registerBridgeImpl(bridgeImpl: independentBridge)
    try await independentClient.crypto().initializeUserCrypto(req: initializedRequest(fixture))

    let provider = FencedTokenProvider()
    let bridge = NativeStateBridge()
    let client = makeClient(endpoint: endpoint, provider: provider, bridge: bridge)
    let gate = PasswordAuthenticationGate(binding: activeBinding)
    guard let attempt = gate.beginAttempt() else { throw ProbeFailure.publication }
    currentFailureStage = "sdk_password_login"
    let response = try await passwordLogin(
      client: client, endpoint: endpoint, fixture: fixture, password: fixture.newPassword)
    guard response.accessToken == expectedAccessToken,
      response.refreshToken == expectedRefreshToken
    else { throw ProbeFailure.login }
    currentFailureStage = "sdk_user_crypto_initialize"
    try await installLoginCrypto(
      client: client, bridge: bridge, fixture: fixture, result: response)
    let bridgeStatePresent = await bridge.hasTransientKeyState()
    print("native_vault_bridge_state=\(bridgeStatePresent ? "present" : "missing")")
    guard bridgeStatePresent else { throw ProbeFailure.userCrypto }
    reportStage("sdk_password_login=passed")
    reportStage("sdk_user_crypto_initialized=passed")

    var stored = false
    let committed = gate.commit(attempt) {
      do {
        try store.write(
          PasswordCredential(
            accessToken: response.accessToken, refreshToken: response.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))),
          for: activeBinding)
        provider.publish(response.accessToken)
        stored = true
      } catch {}
    }
    guard committed, stored, await provider.getAccessToken() == response.accessToken else {
      throw ProbeFailure.publication
    }
    reportStage("gate_store_token_commit=passed")
    guard try store.read(for: activeBinding)?.accessToken == response.accessToken else {
      throw ProbeFailure.publication
    }
    reportStage("credential_store_readback=passed")
    guard
      try store.read(for: independentBinding)?.accessToken
        == "synthetic-independent-context-token"
    else { throw ProbeFailure.publication }

    let sync = client.sync()
    try await sync.sync(force: true)
    let fetched = sync.encryptedCiphers()
    guard fetched.count == 1, fetched[0].id == userID else { throw ProbeFailure.sync }
    reportStage("sdk_sync_fetched_cipher=passed")
    let crypto = client.crypto()
    let cipherClient = client.vault().ciphers()
    guard await decryptsSynthetic(client, cipher: fetched[0]) else {
      throw ProbeFailure.cipherDecrypt
    }
    reportStage("sdk_cipher_decrypted=passed")
    reportStage("mock_sdk_token_observed=passed")
    reportStage("synthetic_https_identity_only=passed")

    gate.setEnabled(false)
    crypto.clearUserCryptoKeys()
    let bridgeWasCleared = await bridge.clearTransientKeyState()
    guard bridgeWasCleared, !(await bridge.hasTransientKeyState()), await isLocked(client) else {
      throw ProbeFailure.lock
    }
    reportStage("lock_sdk_shared_keys_cleared=passed")
    reportStage("lock_host_bridge_cleared=passed")
    do {
      _ = try await crypto.getUserEncryptionKey()
      throw ProbeFailure.lock
    } catch is ProbeFailure {
      throw ProbeFailure.lock
    } catch {
      reportStage("retained_key_read_rejected=passed")
    }
    do {
      _ = try await cipherClient.decrypt(cipher: fetched[0])
      throw ProbeFailure.lock
    } catch is ProbeFailure {
      throw ProbeFailure.lock
    } catch {
      reportStage("retained_cipher_decrypt_rejected=passed")
    }
    guard await decryptsSynthetic(independentClient, cipher: fetched[0]),
      await independentProvider.getAccessToken() == "synthetic-independent-context-token",
      try store.read(for: independentBinding)?.accessToken == "synthetic-independent-context-token"
    else { throw ProbeFailure.lock }
    reportStage("independent_profile_still_usable=passed")

    try await deniedStoreCase(
      endpoint: endpoint, fixture: fixture, store: store,
      sharedVaultID: sharedVaultID, accountID: accountID, fetchedCipher: fetched[0],
      independentClient: independentClient, independentProvider: independentProvider,
      independentBinding: independentBinding)

    try await installLoginCrypto(
      client: client, bridge: bridge, fixture: fixture, result: response)
    guard await decryptsSynthetic(client, cipher: fetched[0]) else { throw ProbeFailure.userCrypto }
    gate.setEnabled(true)
    reportStage("explicit_unlock_reinitialized=passed")
    reportStage("fetched_cipher_decrypted_after_unlock=passed")

    try await lateCommitCase(
      endpoint: endpoint, fixture: fixture, store: store,
      sharedVaultID: sharedVaultID, accountID: accountID,
      fetchedCipher: fetched[0], disable: true)
    try await lateCommitCase(
      endpoint: endpoint, fixture: fixture, store: store,
      sharedVaultID: sharedVaultID, accountID: accountID,
      fetchedCipher: fetched[0], disable: false)

    let failedProfile = UUID()
    let failedBinding = makeBinding(
      profile: failedProfile, vault: sharedVaultID, account: accountID)
    let failedProvider = FencedTokenProvider()
    let failedBridge = NativeStateBridge()
    let failedClient = makeClient(
      endpoint: endpoint, provider: failedProvider, bridge: failedBridge)
    let failedGate = PasswordAuthenticationGate(binding: failedBinding)
    guard let failedAttempt = failedGate.beginAttempt() else { throw ProbeFailure.login }
    do {
      _ = try await passwordLogin(
        client: failedClient, endpoint: endpoint, fixture: fixture,
        password: fixture.newPassword + "-incorrect")
      throw ProbeFailure.login
    } catch is ProbeFailure {
      throw ProbeFailure.login
    } catch {
      failedGate.invalidate(failedAttempt)
      guard await failedProvider.getAccessToken() == nil,
        try store.read(for: failedBinding) == nil,
        !(await failedBridge.hasTransientKeyState())
      else { throw ProbeFailure.publication }
      reportStage("auth_failure_no_publication=passed")
    }

    gate.setEnabled(false)
    provider.clear()
    try store.delete(for: activeBinding)
    guard await provider.getAccessToken() == nil, try store.read(for: activeBinding) == nil else {
      throw ProbeFailure.disconnect
    }
    reportStage("disconnect_owned_record_removed=passed")
    guard await independentProvider.getAccessToken() == "synthetic-independent-context-token",
      try store.read(for: independentBinding)?.accessToken == "synthetic-independent-context-token",
      await decryptsSynthetic(independentClient, cipher: fetched[0])
    else { throw ProbeFailure.disconnect }
    reportStage("independent_record_preserved=passed")

    crypto.clearUserCryptoKeys()
    guard await bridge.clearTransientKeyState(), await isLocked(client) else {
      throw ProbeFailure.disconnect
    }
    try removeOwnedCredentials(store, bindings: [activeBinding, independentBinding])
    reportStage("credential_records_removed=passed")
    print(lifecycleCompletionMarker)
  } catch {
    try removeOwnedCredentials(store, bindings: [activeBinding, independentBinding])
    throw error
  }
}

@main
struct NativeBitwardenLifecycleProbe {
  @MainActor
  static func main() async {
    do {
      let fixture = try decodeFixture()
      guard CommandLine.arguments.count >= 2 else { throw ProbeFailure.fixture }
      let mode = CommandLine.arguments.last!
      if mode == "prepare" {
        try await prepare(fixture)
        return
      }
      guard mode == "lifecycle", CommandLine.arguments.count == 3,
        let endpoint = URL(string: CommandLine.arguments[1]),
        endpoint.scheme == "http", endpoint.host == "127.0.0.1",
        endpoint.port != nil, endpoint.path == "/", endpoint.query == nil,
        endpoint.user == nil, endpoint.password == nil
      else { throw ProbeFailure.fixture }
      try await lifecycle(fixture, endpoint: endpoint)
    } catch {
      print("native_vault_stage=\(currentFailureStage)")
      print("native_vault_error_type=\(safeErrorType(error))")
      exit(1)
    }
  }
}
