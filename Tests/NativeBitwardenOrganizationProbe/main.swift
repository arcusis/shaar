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

private func prepare(_ fixture: FixtureInput, org: String, key: String) async throws {
  let client = makeFixtureClient(tokenProvider: OwnedTokenProvider(token))
  try await installKeys(fixture, client: client)
  try await client.crypto().initializeOrgCrypto(
    req: InitOrgCryptoRequest(organizationKeys: [org: key]))
  let date = Date(timeIntervalSince1970: 0)
  let view = CipherView(
    id: nil, organizationId: org, folderId: nil, collectionIds: [], key: nil,
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
  var responseCipher = try encryptedResponse(encrypted.cipher)
  responseCipher["organizationId"] = org
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

struct Payload: Decodable {
  let fixture: FixtureInput
  let org: String
  let key: String
}
func check(_ v: Bool, _ label: String) throws {
  guard v else {
    print("\(label)=failed")
    throw SafeFailure()
  }
  print("\(label)=passed")
}
func run(_ p: Payload, _ endpoint: URL) async throws {
  let settings = ClientSettings(
    identityUrl: endpoint.absoluteString + "identity", apiUrl: endpoint.absoluteString + "api",
    userAgent: "fixture", deviceType: .sdk,
    deviceIdentifier: "00000000-0000-4000-8000-000000000026", bitwardenClientVersion: "0.0.0",
    bitwardenPackageType: "desktop")
  let client = makeFixtureClient(tokenProvider: OwnedTokenProvider(""), settings: settings)
  let other = makeFixtureClient(tokenProvider: OwnedTokenProvider(""))
  try await installKeys(p.fixture, client: client)
  try check(!(await isLocked(client)), "personal_user_unlocked")
  _ = try await client.sync().sync(force: true)
  let snap = client.sync().encryptedSnapshot()
  try check(
    snap.generation == 1 && snap.ciphers.count == 1 && snap.organizationKeys.count == 1
      && snap.organizationKeys[p.org] == p.key, "snapshot")
  let cipher = snap.ciphers[0]
  try check(cipher.organizationId == p.org, "organization_owner")
  try check(!(await decryptsExpected(client, cipher: cipher)), "missing_key_rejects")
  do {
    try await client.crypto().initializeOrgCrypto(
      req: InitOrgCryptoRequest(organizationKeys: [p.org: "3.AQ=="]))
    throw SafeFailure()
  } catch is SafeFailure { throw SafeFailure() } catch { print("malformed_key=passed") }
  try check(!(await decryptsExpected(client, cipher: cipher)), "malformed_key_rejects_decrypt")
  try await client.crypto().initializeOrgCrypto(
    req: InitOrgCryptoRequest(organizationKeys: snap.organizationKeys))
  let view = try await client.vault().ciphers().decrypt(cipher: cipher)
  try check(view.name == expectedName, "name_match")
  try check(view.login?.username == expectedUsername, "username_match")
  try check(view.login?.password == expectedPassword, "password_match")
  try check(view.organizationId == p.org, "decrypted_organization")
  try check(await decryptsExpected(client, cipher: cipher), "org_decrypt")
  try await client.crypto().initializeOrgCrypto(req: InitOrgCryptoRequest(organizationKeys: [:]))
  try check(await decryptsExpected(client, cipher: cipher), "empty_map_retains_key")
  try check(!(await decryptsExpected(other, cipher: cipher)), "independent_rejects")
  try await installKeys(p.fixture, client: other)
  try await other.crypto().initializeOrgCrypto(
    req: InitOrgCryptoRequest(organizationKeys: snap.organizationKeys))
  try check(await decryptsExpected(other, cipher: cipher), "independent_unlock_decrypts")
  client.crypto().clearUserCryptoKeys()
  try check(!(await decryptsExpected(client, cipher: cipher)), "clear_rejects")
  try check(await decryptsExpected(other, cipher: cipher), "independent_survives_clear")
}
do {
  let p = try JSONDecoder().decode(
    Payload.self, from: FileHandle.standardInput.readDataToEndOfFile())
  if CommandLine.arguments[1] == "prepare" {
    try await prepare(p.fixture, org: p.org, key: p.key)
  } else {
    guard let url = URL(string: CommandLine.arguments[1]), url.scheme == "http",
      url.host == "127.0.0.1", url.port != nil
    else { throw SafeFailure() }
    try await run(p, url)
  }
} catch {
  print("runtime=failed")
  exit(1)
}
