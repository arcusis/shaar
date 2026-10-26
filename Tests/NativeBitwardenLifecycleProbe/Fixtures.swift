import BitwardenFFI
import Foundation

struct FixtureInput: Decodable {
  let email: String
  let userID: String
  let currentPassword: String
  let newPassword: String
  let privateKey: String
  let wrappedUserKey: String
  let iterations: UInt32
  let passwordHash: String?
  let newKey: String?
  let encryptedCipherBase64: String?
}

struct PreparedFixture: Encodable {
  let passwordHash: String
  let newKey: String
  let encryptedCipherBase64: String
}

actor NativeStateBridge: StateBridgeForeignImpl {
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
  func setV2EncryptedMigrationsGracePeriodStart(
    value: V2EncryptedMigrationsGracePeriodStart
  ) async {
    v2GracePeriodStart = value
  }
  func getV2EncryptedMigrationsGracePeriodStart() async -> V2EncryptedMigrationsGracePeriodStart? {
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

final class FencedTokenProvider: ClientManagedTokens, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?

  func getAccessToken() async -> String? {
    lock.withLock { token }
  }

  func publish(_ value: String) {
    lock.withLock { token = value }
  }

  func clear() {
    lock.withLock { token = nil }
  }
}

struct DeniedCredentialStorage: PasswordCredentialItemStorage {
  func read(service: String, account: String) throws -> Data? { nil }

  func write(_ data: Data, service: String, account: String) throws {
    throw PasswordCredentialStorageFailure(status: -25291)
  }

  func delete(service: String, account: String) throws {}
}

func decodeFixture() throws -> FixtureInput {
  try JSONDecoder().decode(FixtureInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
}
