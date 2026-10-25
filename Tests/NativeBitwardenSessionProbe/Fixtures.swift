import BitwardenFFI
import Foundation

struct FixtureInput: Decodable {
  let email: String
  let userID: String
  let currentPassword: String?
  let newPassword: String
  let privateKey: String
  let wrappedUserKey: String?
  let iterations: UInt32
  let passwordHash: String?
  let newKey: String?
}

struct PreparedFixture: Encodable {
  let email: String
  let passwordHash: String
  let newKey: String
  let privateKey: String
  let iterations: UInt32
}

actor OwnedTokenProvider: ClientManagedTokens {
  private var accessToken: String?

  init(accessToken: String? = nil) {
    self.accessToken = accessToken
  }

  func getAccessToken() async -> String? { accessToken }

  func publish(_ token: String) { accessToken = token }
}

actor InMemoryStateBridge: StateBridgeForeignImpl {
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
  func getMasterpasswordUnlockData() async -> MasterPasswordUnlockData? { masterPasswordUnlockData }
  func clearMasterpasswordUnlockData() async { masterPasswordUnlockData = nil }
  func setWebauthnPrfUnlockData(value: WebAuthnPrfUnlockData) async {
    webauthnPRFUnlockData = value
  }
  func getWebauthnPrfUnlockData() async -> WebAuthnPrfUnlockData? { webauthnPRFUnlockData }
  func clearWebauthnPrfUnlockData() async { webauthnPRFUnlockData = nil }
  func setKdfConfig(value: Kdf) async { kdfConfig = value }
  func getKdfConfig() async -> Kdf? { kdfConfig }
  func clearKdfConfig() async { kdfConfig = nil }
  func setV2EncryptedMigrationsGracePeriodStart(value: V2EncryptedMigrationsGracePeriodStart) async
  {
    v2GracePeriodStart = value
  }
  func getV2EncryptedMigrationsGracePeriodStart() async -> V2EncryptedMigrationsGracePeriodStart? {
    v2GracePeriodStart
  }
  func clearV2EncryptedMigrationsGracePeriodStart() async { v2GracePeriodStart = nil }
}

func decodeFixture() throws -> FixtureInput {
  let data = FileHandle.standardInput.readDataToEndOfFile()
  return try JSONDecoder().decode(FixtureInput.self, from: data)
}

func makeFixtureClient(
  tokenProvider: OwnedTokenProvider,
  stateBridge: InMemoryStateBridge,
  settings: ClientSettings? = nil
) -> Client {
  let client = Client(
    tokenProvider: tokenProvider,
    settings: settings,
    managedSettings: ManagedSettingsBindingClient())
  client.kmStateBridge().registerBridgeImpl(bridgeImpl: stateBridge)
  return client
}
