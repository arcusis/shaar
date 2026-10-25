import BitwardenFFI
import Foundation

struct NativeCryptoFixture: Decodable {
  let userId: String
  let email: String
  let password: String
  let privateKey: String
  let masterKeyWrappedUserKey: String
  let iterations: UInt32

  static func load() throws -> NativeCryptoFixture {
    guard let path = ProcessInfo.processInfo.environment["BITWARDEN_FIXTURE_PATH"] else {
      throw ProbeFailure.fixtureUnavailable
    }
    return try JSONDecoder().decode(
      NativeCryptoFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  func request() -> InitUserCryptoRequest {
    let kdf = Kdf.pbkdf2(iterations: iterations)
    return InitUserCryptoRequest(
      userId: userId,
      kdfParams: kdf,
      email: email,
      accountCryptographicState: .v1(privateKey: privateKey),
      method: .masterPasswordUnlock(
        password: password,
        masterPasswordUnlock: MasterPasswordUnlockData(
          kdf: kdf,
          masterKeyWrappedUserKey: masterKeyWrappedUserKey,
          salt: email,
          containedKeyId: nil
        )
      ),
      upgradeToken: nil
    )
  }
}

enum ProbeFailure: Error {
  case fixtureUnavailable
  case keyReadStillAvailable
  case decryptStillAvailable
  case independentClientLostKeys
  case reinitializationFailed
  case cipherRoundTripFailed
}

final class EmptyTokenProvider: ClientManagedTokens {
  func getAccessToken() async -> String? { nil }
}

actor NativeStateBridge: StateBridgeForeignImpl {
  private var userKey: SymmetricCryptoKey?
  private var userKeyId: KeyId?
  private var persistentPinEnvelope: PasswordProtectedKeyEnvelope?
  private var ephemeralPinEnvelope: PasswordProtectedKeyEnvelope?
  private var encryptedPin: EncString?
  private var upgradeToken: V2UpgradeToken?
  private var accountCryptoState: WrappedAccountCryptographicState?
  private var masterPasswordUnlockData: MasterPasswordUnlockData?
  private var webauthnPrfUnlockData: WebAuthnPrfUnlockData?
  private var kdfConfig: Kdf?
  private var v2GracePeriodStart: V2EncryptedMigrationsGracePeriodStart?

  func setUserKey(value: SymmetricCryptoKey) async { userKey = value }
  func getUserKey() async -> SymmetricCryptoKey? { userKey }
  func clearUserKey() async { userKey = nil }
  func setUserKeyId(value: KeyId) async { userKeyId = value }
  func getUserKeyId() async -> KeyId? { userKeyId }
  func clearUserKeyId() async { userKeyId = nil }
  func setPersistentPinEnvelope(value: PasswordProtectedKeyEnvelope) async {
    persistentPinEnvelope = value
  }
  func getPersistentPinEnvelope() async -> PasswordProtectedKeyEnvelope? { persistentPinEnvelope }
  func clearPersistentPinEnvelope() async { persistentPinEnvelope = nil }
  func setEphemeralPinEnvelope(value: PasswordProtectedKeyEnvelope) async {
    ephemeralPinEnvelope = value
  }
  func getEphemeralPinEnvelope() async -> PasswordProtectedKeyEnvelope? { ephemeralPinEnvelope }
  func clearEphemeralPinEnvelope() async { ephemeralPinEnvelope = nil }
  func setEncryptedPin(value: EncString) async { encryptedPin = value }
  func getEncryptedPin() async -> EncString? { encryptedPin }
  func clearEncryptedPin() async { encryptedPin = nil }
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
    webauthnPrfUnlockData = value
  }
  func getWebauthnPrfUnlockData() async -> WebAuthnPrfUnlockData? { webauthnPrfUnlockData }
  func clearWebauthnPrfUnlockData() async { webauthnPrfUnlockData = nil }
  func setKdfConfig(value: Kdf) async { kdfConfig = value }
  func getKdfConfig() async -> Kdf? { kdfConfig }
  func clearKdfConfig() async { kdfConfig = nil }
  func setV2EncryptedMigrationsGracePeriodStart(
    value: V2EncryptedMigrationsGracePeriodStart
  ) async {
    v2GracePeriodStart = value
  }
  func getV2EncryptedMigrationsGracePeriodStart() async -> V2EncryptedMigrationsGracePeriodStart? {
    v2GracePeriodStart
  }
  func clearV2EncryptedMigrationsGracePeriodStart() async { v2GracePeriodStart = nil }

}

func makeInitializedClient(fixture: NativeCryptoFixture) async throws -> Client {
  let bridge = NativeStateBridge()
  let client = Client(
    tokenProvider: EmptyTokenProvider(), settings: nil,
    managedSettings: ManagedSettingsBindingClient())
  client.kmStateBridge().registerBridgeImpl(bridgeImpl: bridge)
  try await client.crypto().initializeUserCrypto(req: fixture.request())
  return client
}

func makeSyntheticCipherView() -> CipherView {
  let now = Date(timeIntervalSince1970: 0)
  return CipherView(
    id: nil, organizationId: nil, folderId: nil, collectionIds: [], key: nil,
    name: "synthetic-key-clear-probe", notes: "synthetic note", type: .login,
    login: LoginView(
      username: "fixture-user", password: "fixture-pass", passwordRevisionDate: nil, uris: nil,
      totp: nil, autofillOnPageLoad: nil, fido2Credentials: nil),
    identity: nil, card: nil, secureNote: nil, sshKey: nil, bankAccount: nil,
    driversLicense: nil, passport: nil, favorite: false, reprompt: .none,
    organizationUseTotp: false, edit: true, permissions: nil, viewPassword: true,
    localData: nil, attachments: nil, attachmentDecryptionFailures: nil,
    fields: nil, passwordHistory: nil, creationDate: now, deletedDate: nil,
    revisionDate: now, archivedDate: nil, partial: false
  )
}
