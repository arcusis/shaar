import BitwardenFFI
import Foundation

private struct SafeFailure: Error {}

private let deviceID = "00000000-0000-4000-8000-000000000026"
private let cipherName = "native-session-roundtrip"
private let cipherUsername = "synthetic-user"
private let cipherPassword = "synthetic-cipher-value"

private func kdf(iterations: UInt32) -> Kdf {
  .pbkdf2(iterations: iterations)
}

private func prepare(_ fixture: FixtureInput) async throws {
  guard let currentPassword = fixture.currentPassword,
    let wrappedUserKey = fixture.wrappedUserKey
  else {
    print("session_stage=crypto_fixture_incomplete")
    throw SafeFailure()
  }
  let bridge = InMemoryStateBridge()
  let client = makeFixtureClient(tokenProvider: OwnedTokenProvider(), stateBridge: bridge)
  let request = InitUserCryptoRequest(
    userId: fixture.userID,
    kdfParams: kdf(iterations: fixture.iterations),
    email: fixture.email,
    accountCryptographicState: .v1(privateKey: fixture.privateKey),
    method: .masterPasswordUnlock(
      password: currentPassword,
      masterPasswordUnlock: MasterPasswordUnlockData(
        kdf: kdf(iterations: fixture.iterations),
        masterKeyWrappedUserKey: wrappedUserKey,
        salt: fixture.email,
        containedKeyId: nil)),
    upgradeToken: nil)
  do {
    try await client.crypto().initializeUserCrypto(req: request)
  } catch {
    print("crypto_vector_initialize=failed")
    throw SafeFailure()
  }
  let updated: UpdatePasswordResponse
  do {
    updated = try await client.crypto().makeUpdatePassword(newPassword: fixture.newPassword)
  } catch {
    print("sdk_password_update=failed")
    throw SafeFailure()
  }
  let result = PreparedFixture(
    email: fixture.email,
    passwordHash: updated.passwordHash,
    newKey: updated.newKey,
    privateKey: fixture.privateKey,
    iterations: fixture.iterations)
  FileHandle.standardOutput.write(try JSONEncoder().encode(result))
}

private func login(_ fixture: FixtureInput, endpoint: URL, invalid: Bool) async throws {
  guard let passwordHash = fixture.passwordHash, let newKey = fixture.newKey else {
    print("session_stage=crypto_fixture_incomplete")
    throw SafeFailure()
  }
  let provider = OwnedTokenProvider()
  let independentProvider = OwnedTokenProvider(accessToken: "independent-context-token")
  let independentClient = makeFixtureClient(
    tokenProvider: independentProvider, stateBridge: InMemoryStateBridge())
  let candidateClient = makeFixtureClient(
    tokenProvider: provider, stateBridge: InMemoryStateBridge(),
    settings: ClientSettings(
      identityUrl: endpoint.absoluteString + "identity",
      apiUrl: endpoint.absoluteString + "api",
      userAgent: "Arcusis native session proof",
      deviceType: .sdk,
      deviceIdentifier: deviceID,
      bitwardenClientVersion: "0.0.0-synthetic",
      bitwardenPackageType: "desktop"))
  let client = candidateClient
  let auth = client.auth().login()
  let prelogin: PasswordPreloginResponse
  do {
    prelogin = try await auth.getPasswordPrelogin(email: fixture.email)
  } catch {
    print("session_stage=prelogin_sdk_error")
    throw SafeFailure()
  }
  guard prelogin.kdf == kdf(iterations: fixture.iterations), prelogin.salt == fixture.email else {
    print("session_stage=prelogin_mismatch")
    throw SafeFailure()
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
    password: fixture.newPassword,
    preloginResponse: prelogin,
    twoFactor: nil)
  let loginResponse: LoginResponse
  do {
    loginResponse = try await auth.loginViaPassword(request: request)
  } catch {
    print("session_stage=password_login_sdk_error")
    throw SafeFailure()
  }
  guard case .authenticated(let response) = loginResponse,
    response.accessToken == "synthetic-session-token",
    response.wrappedAccountCryptoState != nil,
    let unlock = response.userDecryptionOptions.masterPasswordUnlock
  else {
    print("session_stage=login_response_mismatch")
    throw SafeFailure()
  }

  let installedUnlock =
    invalid
    ? MasterPasswordUnlockData(
      kdf: unlock.kdf,
      masterKeyWrappedUserKey: "invalid-typed-wrapped-key",
      salt: unlock.salt,
      containedKeyId: nil)
    : unlock
  let cryptoRequest = InitUserCryptoRequest(
    userId: fixture.userID,
    kdfParams: prelogin.kdf,
    email: fixture.email,
    accountCryptographicState: response.wrappedAccountCryptoState!,
    method: .masterPasswordUnlock(
      password: fixture.newPassword, masterPasswordUnlock: installedUnlock),
    upgradeToken: nil)
  if invalid {
    // A well-formed wrapped key must also reject the wrong master password.
    let wrongPasswordRequest = InitUserCryptoRequest(
      userId: fixture.userID,
      kdfParams: prelogin.kdf,
      email: fixture.email,
      accountCryptographicState: response.wrappedAccountCryptoState!,
      method: .masterPasswordUnlock(
        password: fixture.newPassword + "-incorrect", masterPasswordUnlock: unlock),
      upgradeToken: nil)
    do {
      try await client.crypto().initializeUserCrypto(req: wrongPasswordRequest)
      throw SafeFailure()
    } catch is SafeFailure {
      throw SafeFailure()
    } catch {
      guard await provider.getAccessToken() == nil, await isLocked(client),
        await isLocked(independentClient)
      else { throw SafeFailure() }
    }
    do {
      try await client.crypto().initializeUserCrypto(req: cryptoRequest)
      throw SafeFailure()
    } catch is SafeFailure {
      throw SafeFailure()
    } catch {
      let candidateKeyUnavailable: Bool
      do {
        _ = try await client.crypto().getUserEncryptionKey()
        candidateKeyUnavailable = false
      } catch {
        candidateKeyUnavailable = true
      }
      guard await provider.getAccessToken() == nil,
        candidateKeyUnavailable,
        await independentProvider.getAccessToken() == "independent-context-token",
        await isLocked(independentClient)
      else { throw SafeFailure() }
      print("invalid_crypto_setup=rejected")
      print("token_publication=none")
      print("candidate_key=unavailable")
      print("independent_client=locked")
      print("independent_context=preserved")
      return
    }
  }

  guard installedUnlock.salt == fixture.email,
    installedUnlock.kdf == prelogin.kdf,
    installedUnlock.masterKeyWrappedUserKey == newKey
  else { throw SafeFailure() }
  do {
    try await client.crypto().initializeUserCrypto(req: cryptoRequest)
  } catch {
    print("session_stage=user_crypto_install_error")
    throw SafeFailure()
  }
  await provider.publish(response.accessToken)
  guard await provider.getAccessToken() == "synthetic-session-token",
    await independentProvider.getAccessToken() == "independent-context-token",
    await isLocked(independentClient)
  else { throw SafeFailure() }

  let now = Date(timeIntervalSince1970: 0)
  let view = CipherView(
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
    fields: nil, passwordHistory: nil, creationDate: now, deletedDate: nil,
    revisionDate: now, archivedDate: nil, partial: false)
  let encrypted: EncryptionContext
  do {
    encrypted = try await client.vault().ciphers().encrypt(cipherView: view)
  } catch {
    print("session_stage=cipher_encrypt_error")
    throw SafeFailure()
  }
  let decrypted: CipherView
  do {
    decrypted = try await client.vault().ciphers().decrypt(cipher: encrypted.cipher)
  } catch {
    print("session_stage=cipher_decrypt_error")
    throw SafeFailure()
  }
  guard decrypted.name == cipherName,
    decrypted.login?.username == cipherUsername,
    decrypted.login?.password == cipherPassword
  else {
    print("session_stage=cipher_roundtrip_mismatch")
    throw SafeFailure()
  }
  print("swift_login=passed")
  print("user_key_installation=passed")
  print("cipher_roundtrip=passed")
  print("token_publication=owned-provider")
  print("independent_client=locked")
  print("independent_context=preserved")
}

private func isLocked(_ client: Client) async -> Bool {
  do {
    _ = try await client.crypto().getUserEncryptionKey()
    return false
  } catch {
    return true
  }
}

func runNativeSessionProbe() async {
  guard CommandLine.arguments.count >= 2,
    let mode = CommandLine.arguments.last,
    ["prepare", "login", "invalid"].contains(mode)
  else {
    print("session_probe=invalid_input")
    exit(2)
  }
  do {
    let fixture: FixtureInput
    do {
      fixture = try decodeFixture()
    } catch {
      print("session_stage=input_decode_error")
      throw SafeFailure()
    }
    if mode == "prepare" {
      try await prepare(fixture)
      return
    }
    guard CommandLine.arguments.count == 3,
      let endpoint = URL(string: CommandLine.arguments[1]),
      endpoint.scheme == "http", endpoint.host == "127.0.0.1",
      endpoint.port != nil, endpoint.path.isEmpty || endpoint.path == "/"
    else {
      print("session_stage=endpoint_invalid")
      throw SafeFailure()
    }
    try await login(fixture, endpoint: endpoint, invalid: mode == "invalid")
  } catch {
    print("native_session=failed")
    exit(1)
  }
}

await runNativeSessionProbe()
