// Foundation-only synthetic SDK8 consumer. No browser or persistent stores.
import Foundation
import ArcusisBitwardenSDK

private struct Vector: Decodable {
  let endpoint, email, userID, currentPassword, privateKey, wrappedUserKey: String
  let iterations: UInt32
}
private struct Failure: Error {}
private func require(_ condition: Bool) throws {
  if !condition { throw Failure() }
}
private final class Token: ClientManagedTokens, @unchecked Sendable {
  func getAccessToken() async -> String? { "synthetic-owned-token" }
}
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
private func optional(_ value: Any?) -> Any { value ?? NSNull() }
private func control(_ endpoint: URL, path: String, body: Data? = nil) async throws -> Data {
  var request = URLRequest(url: endpoint.appendingPathComponent(path))
  request.timeoutInterval = 4
  request.httpMethod = body == nil ? "GET" : "POST"
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
  guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure() }
  return data
}

@main struct StrictWriteConsumer {
  static func main() async throws {
    guard let encoded = ProcessInfo.processInfo.environment["ARCUSIS_STRICT_VECTOR"],
      let data = Data(base64Encoded: encoded) else { throw Failure() }
    let fixture = try JSONDecoder().decode(Vector.self, from: data)
    guard let endpoint = URL(string: fixture.endpoint), endpoint.scheme == "http",
      endpoint.host == "127.0.0.1", endpoint.port != nil, endpoint.path.isEmpty,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
    else { throw Failure() }
    let settings = ClientSettings(identityUrl: fixture.endpoint + "/identity", apiUrl: fixture.endpoint + "/api",
      userAgent: "owned SDK fixture", deviceType: .sdk, deviceIdentifier: UUID().uuidString,
      bitwardenClientVersion: "0.1.0", bitwardenPackageType: "desktop")
    let client = Client(tokenProvider: Token(), settings: settings, managedSettings: ManagedSettingsBindingClient())
    let bridge = NativeBitwardenStateBridge()
    client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
    let kdf = Kdf.pbkdf2(iterations: fixture.iterations)
    try await client.crypto().initializeUserCrypto(req: InitUserCryptoRequest(
      userId: fixture.userID, kdfParams: kdf, email: fixture.email,
      accountCryptographicState: .v1(privateKey: fixture.privateKey),
      method: .masterPasswordUnlock(password: fixture.currentPassword,
        masterPasswordUnlock: MasterPasswordUnlockData(kdf: kdf, masterKeyWrappedUserKey: fixture.wrappedUserKey,
          salt: fixture.email, containedKeyId: nil)), upgradeToken: nil))
    defer { client.crypto().clearUserCryptoKeys() }
    if ProcessInfo.processInfo.environment["ARCUSIS_STRICT_RELEASE"] == "1" {
      do { _ = try await client.sync().sync(force: true) }
      catch { print("strict-sdk8-release-http=rejected"); return }
      throw Failure()
    }
    let id = "11111111-1111-4111-8111-111111111111"
    let attachment = AttachmentView(id: "attachment-a", url: "https://files.invalid/synthetic", size: "123",
      sizeName: "123 bytes", fileName: "synthetic-attachment.txt",
      key: Data(repeating: 7, count: 64).base64EncodedString())
    let view = CipherView(id: id, organizationId: nil, folderId: nil, collectionIds: [], key: nil,
      name: "synthetic-title", notes: "synthetic-note", type: .login,
      login: LoginView(username: "synthetic-old-user", password: "synthetic-old-password", passwordRevisionDate: nil,
        uris: [LoginUriView(uri: "https://example.invalid/login", match: .host, uriChecksum: nil)],
        totp: "synthetic-totp", autofillOnPageLoad: nil, fido2Credentials: nil),
      identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil, driversLicense: nil,
      passport: nil, favorite: true, reprompt: .none, organizationUseTotp: false, edit: true,
      permissions: nil, viewPassword: true, localData: nil, attachments: [attachment],
      attachmentDecryptionFailures: nil, fields: [FieldView(name: "synthetic-field", value: "synthetic-value", type: .text, linkedId: nil)],
      passwordHistory: nil, creationDate: Date(timeIntervalSince1970: 1704067200), deletedDate: nil,
      revisionDate: Date(timeIntervalSince1970: 1735689600), archivedDate: nil, partial: false)
    let encrypted = try await client.vault().ciphers().encrypt(cipherView: view).cipher
    guard let login = encrypted.login, let part = encrypted.attachments?.first,
      let uri = login.uris?.first, let field = encrypted.fields?.first else { throw Failure() }
    let seed: [String: Any] = ["id": id, "key": optional(encrypted.key),
      "name": optional(encrypted.name), "notes": optional(encrypted.notes),
      "login": ["username": optional(login.username), "password": optional(login.password),
        "uris": [["uri": optional(uri.uri), "match": 1, "uriChecksum": optional(uri.uriChecksum)]],
        "totp": optional(login.totp), "passwordRevisionDate": NSNull(), "autofillOnPageLoad": NSNull(), "fido2Credentials": NSNull()],
      "fields": [["name": optional(field.name), "value": optional(field.value), "type": 0, "linkedId": NSNull()]],
      "attachments": [["object": "attachment", "id": optional(part.id), "url": optional(part.url),
        "size": optional(part.size), "sizeName": optional(part.sizeName),
        "fileName": optional(part.fileName), "key": optional(part.key)]]]
    _ = try await control(endpoint, path: "fixture/seed", body: JSONSerialization.data(withJSONObject: seed))
    let sync = client.sync()
    try require(try await sync.sync(force: true))
    let first = sync.encryptedSnapshot()
    guard let stale = client.strictPreparePersonalLogin(cipherId: id, expectedGeneration: first.generation),
      let selected = client.strictPreparePersonalLogin(cipherId: id, expectedGeneration: first.generation) else { throw Failure() }
    try require(selected.revisionToken() == "2025-01-01T00:00:00.123456789Z")
    let other = Client(tokenProvider: Token(), settings: settings, managedSettings: ManagedSettingsBindingClient())
    guard case .rejectedBeforeDispatch = await other.strictPersonalUpdate(preparation: selected, username: nil, password: "synthetic-other") else { throw Failure() }
    guard case .unconfirmed = await client.strictPersonalUpdate(preparation: selected, username: "synthetic-new-user", password: "synthetic-new-password") else { throw Failure() }
    guard case .rejectedBeforeDispatch = await client.strictPersonalUpdate(preparation: stale, username: nil, password: "synthetic-stale") else { throw Failure() }
    try require(try await sync.sync(force: true))
    let next = sync.encryptedSnapshot()
    let decrypted = try await client.vault().ciphers().decrypt(cipher: next.ciphers[0])
    try require(decrypted.login?.password == "synthetic-new-password")
    try require(decrypted.name == view.name && decrypted.notes == view.notes && decrypted.fields == view.fields)
    try require(decrypted.attachments == view.attachments)
    for _ in 0..<8 {
      let snapshot = sync.encryptedSnapshot()
      guard let prep = client.strictPreparePersonalLogin(cipherId: id, expectedGeneration: snapshot.generation) else { throw Failure() }
      try require(prep.revisionToken() == "2025-01-01T00:00:00.123456790Z")
      guard case .unconfirmed = await client.strictPersonalUpdate(preparation: prep, username: nil, password: "synthetic-later") else { throw Failure() }
      try require(try await sync.sync(force: true))
    }
    let final = sync.encryptedSnapshot()
    guard let pending = client.strictPreparePersonalLogin(cipherId: id, expectedGeneration: final.generation) else { throw Failure() }
    let write = Task { await client.strictPersonalUpdate(preparation: pending, username: nil, password: "synthetic-cancelled") }
    var started = false
    for _ in 0..<80 {
      if String(data: try await control(endpoint, path: "fixture/status"), encoding: .utf8) == "ready" { started = true; break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    try require(started)
    write.cancel()
    _ = try await control(endpoint, path: "fixture/release")
    _ = await write.value
    guard case .rejectedBeforeDispatch = await client.strictPersonalUpdate(preparation: pending, username: nil, password: "synthetic-replay") else { throw Failure() }
    print("strict-sdk8-consumer=passed")
  }
}
