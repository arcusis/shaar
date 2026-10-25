import BitwardenFFI
import Foundation

private struct SafeFailure: Error {}

private let expectedName = "native-sync-item"
private let expectedUsername = "synthetic-sync-user"
private let expectedPassword = "synthetic-sync-password"
private let token = "synthetic-sync-token"
private let cipherID = "00000000-0000-4000-8000-000000000103"

private func kdf(_ iterations: UInt32) -> Kdf { .pbkdf2(iterations: iterations) }

private func installKeys(_ fixture: FixtureInput, client: Client) async throws {
  let request = InitUserCryptoRequest(
    userId: fixture.userID,
    kdfParams: kdf(fixture.iterations),
    email: fixture.email,
    accountCryptographicState: .v1(privateKey: fixture.privateKey),
    method: .masterPasswordUnlock(
      password: fixture.currentPassword,
      masterPasswordUnlock: MasterPasswordUnlockData(
        kdf: kdf(fixture.iterations),
        masterKeyWrappedUserKey: fixture.wrappedUserKey,
        salt: fixture.email,
        containedKeyId: nil)),
    upgradeToken: nil)
  do { try await client.crypto().initializeUserCrypto(req: request) } catch { throw SafeFailure() }
}

private func encryptedResponse(_ cipher: Cipher) throws -> [String: Any] {
  let formatter = ISO8601DateFormatter()
  var value: [String: Any] = [
    "object": "cipher",
    "id": cipherID,
    "type": cipher.type.rawValue,
    "creationDate": formatter.string(from: Date(timeIntervalSince1970: 0)),
    "revisionDate": formatter.string(from: Date(timeIntervalSince1970: 0)),
    "favorite": cipher.favorite,
    "organizationUseTotp": cipher.organizationUseTotp,
    "edit": cipher.edit,
    "viewPassword": cipher.viewPassword,
  ]
  if let name = cipher.name { value["name"] = name }
  if let notes = cipher.notes { value["notes"] = notes }
  if let key = cipher.key { value["key"] = key }
  if let data = cipher.data { value["data"] = data }
  if let login = cipher.login {
    var loginValue: [String: Any] = [:]
    if let username = login.username { loginValue["username"] = username }
    if let password = login.password { loginValue["password"] = password }
    if let totp = login.totp { loginValue["totp"] = totp }
    if let uris = login.uris { loginValue["uris"] = uris.map { ["uri": $0.uri as Any] } }
    value["login"] = loginValue
  }
  return value
}

private func prepare(_ fixture: FixtureInput) async throws {
  let client = makeFixtureClient(tokenProvider: OwnedTokenProvider(token))
  try await installKeys(fixture, client: client)
  let date = Date(timeIntervalSince1970: 0)
  let view = CipherView(
    id: nil, organizationId: nil, folderId: nil, collectionIds: [], key: nil,
    name: expectedName, notes: nil, type: .login,
    login: LoginView(
      username: expectedUsername, password: expectedPassword,
      passwordRevisionDate: nil, uris: nil, totp: nil, autofillOnPageLoad: nil,
      fido2Credentials: nil),
    identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
    driversLicense: nil, passport: nil, favorite: false, reprompt: .none,
    organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true,
    localData: nil, attachments: nil, attachmentDecryptionFailures: nil,
    fields: nil, passwordHistory: nil, creationDate: date, deletedDate: nil,
    revisionDate: date, archivedDate: nil, partial: false)
  let encrypted: EncryptionContext
  do { encrypted = try await client.vault().ciphers().encrypt(cipherView: view) } catch {
    throw SafeFailure()
  }
  let responseCipher = try encryptedResponse(encrypted.cipher)
  let bytes = try JSONSerialization.data(
    withJSONObject: [
      "cipher": responseCipher,
      "expectedName": expectedName,
      "expectedUsername": expectedUsername,
      "expectedPassword": expectedPassword,
    ], options: [.sortedKeys])
  FileHandle.standardOutput.write(bytes)
}

private func decryptsExpected(_ client: Client, cipher: Cipher) async -> Bool {
  do {
    let view = try await client.vault().ciphers().decrypt(cipher: cipher)
    return view.name == expectedName
      && view.login?.username == expectedUsername
      && view.login?.password == expectedPassword
  } catch {
    return false
  }
}

private func isLocked(_ client: Client) async -> Bool {
  do {
    _ = try await client.crypto().getUserEncryptionKey()
    return false
  } catch {
    return true
  }
}

private func exerciseSync(_ fixture: FixtureInput, endpoint: URL) async throws {
  let provider = OwnedTokenProvider(token)
  let client = makeFixtureClient(
    tokenProvider: provider,
    settings: ClientSettings(
      identityUrl: endpoint.absoluteString + "identity",
      apiUrl: endpoint.absoluteString + "api",
      userAgent: "Arcusis native sync proof",
      deviceType: .sdk,
      deviceIdentifier: "00000000-0000-4000-8000-000000000026",
      bitwardenClientVersion: "0.0.0-synthetic",
      bitwardenPackageType: "desktop"))
  let independentToken = "independent-context-token"
  let independentProvider = OwnedTokenProvider(independentToken)
  let independent = makeFixtureClient(tokenProvider: independentProvider)
  try await installKeys(fixture, client: client)
  let sync = client.sync()
  do {
    _ = try await sync.sync(force: true)
  } catch {
    print("sync_stage=fetch_failed")
    throw SafeFailure()
  }
  let snapshot = sync.encryptedCiphers()
  guard snapshot.count == 1 else {
    print("sync_stage=snapshot_count")
    throw SafeFailure()
  }
  let decrypted: CipherView
  do { decrypted = try await client.vault().ciphers().decrypt(cipher: snapshot[0]) } catch {
    print("sync_stage=decrypt_failed")
    throw SafeFailure()
  }
  guard decrypted.name == expectedName,
    decrypted.login?.username == expectedUsername,
    decrypted.login?.password == expectedPassword
  else {
    print("sync_stage=decrypted_values_mismatch")
    throw SafeFailure()
  }
  let originalSnapshot = snapshot
  print("fetched_cipher_decrypted=passed")
  print("host_token_sync_request=passed")

  do {
    _ = try await sync.sync(force: true)
    print("sync_stage=unauthenticated_accepted")
    throw SafeFailure()
  } catch is SafeFailure { throw SafeFailure() } catch {
    let afterUnauthorized = sync.encryptedCiphers()
    var contentsPreserved = false
    if afterUnauthorized.count == 1 {
      contentsPreserved = await decryptsExpected(client, cipher: afterUnauthorized[0])
    }
    guard afterUnauthorized == originalSnapshot, contentsPreserved else { throw SafeFailure() }
    print("unauthenticated_snapshot_preserved=passed")
  }
  do {
    _ = try await sync.sync(force: true)
    print("sync_stage=malformed_accepted")
    throw SafeFailure()
  } catch is SafeFailure { throw SafeFailure() } catch {
    let afterMalformed = sync.encryptedCiphers()
    var contentsPreserved = false
    if afterMalformed.count == 1 {
      contentsPreserved = await decryptsExpected(client, cipher: afterMalformed[0])
    }
    guard afterMalformed == originalSnapshot, contentsPreserved else { throw SafeFailure() }
    print("malformed_snapshot_preserved=passed")
  }
  let independentSnapshotEmpty = independent.sync().encryptedCiphers().isEmpty
  let independentTokenPreserved = await independentProvider.getAccessToken() == independentToken
  let independentCryptoLocked = await isLocked(independent)
  guard independentSnapshotEmpty,
    independentTokenPreserved,
    independentCryptoLocked,
    await provider.getAccessToken() == token
  else { throw SafeFailure() }
  print("independent_client_unchanged=passed")
  print("snapshot_publication=success_only")
}

func runNativeSyncProbe() async {
  guard CommandLine.arguments.count >= 2,
    let mode = CommandLine.arguments.last,
    ["prepare", "sync"].contains(mode)
  else {
    print("sync_probe=invalid_input")
    exit(2)
  }
  do {
    let fixture = try decodeFixture()
    if mode == "prepare" {
      try await prepare(fixture)
      return
    }
    guard CommandLine.arguments.count == 3,
      let endpoint = URL(string: CommandLine.arguments[1]),
      endpoint.scheme == "http", endpoint.host == "127.0.0.1",
      endpoint.port != nil, endpoint.path.isEmpty || endpoint.path == "/"
    else {
      print("sync_stage=endpoint_invalid")
      throw SafeFailure()
    }
    try await exerciseSync(fixture, endpoint: endpoint)
  } catch {
    print("native_sync=failed")
    exit(1)
  }
}

await runNativeSyncProbe()
