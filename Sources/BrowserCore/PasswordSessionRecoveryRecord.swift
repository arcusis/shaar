import Foundation

/// Versioned, binding-scoped recovery data. SDK-specific wrapped values must be
/// decoded and validated by the SDK adapter before they are used.
public struct PasswordSessionRecoveryRecord: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public enum State: String, Codable, Sendable {
    case ready
    case refreshInFlight
    case reauthenticationRequired
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case bindingMismatch
    case tooLarge
  }

  private struct Payload: Codable, Equatable, Sendable {
    let version: Int
    let profileID: UUID
    let vaultID: UUID
    let accountID: UUID
    let authority: String
    let identityURL: String
    let apiURL: String
    let serviceID: String
    let deviceID: UUID
    let clientID: String
    let email: String
    let sdkRevision: String
    let kdf: Data
    let wrappedAccountState: Data
    let masterPasswordUnlockData: Data
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let revision: UInt64
    let state: State
  }

  private static let maxRecordBytes = 128 * 1024
  private static let maxWrappedBytes = 32 * 1024
  private let payload: Payload

  public var credential: PasswordCredential {
    PasswordCredential(
      accessToken: payload.accessToken, refreshToken: payload.refreshToken,
      expiresAt: payload.expiresAt)
  }
  public var accountID: UUID { payload.accountID }
  public var revision: UInt64 { payload.revision }
  public var state: State { payload.state }
  public var identityURL: URL { URL(string: payload.identityURL)! }
  public var apiURL: URL { URL(string: payload.apiURL)! }
  public var serviceID: String { payload.serviceID }
  public var deviceID: UUID { payload.deviceID }
  public var email: String { payload.email }
  public var clientID: String { payload.clientID }
  public var sdkRevision: String { payload.sdkRevision }
  public var kdf: Data { payload.kdf }
  public var wrappedAccountState: Data { payload.wrappedAccountState }
  public var masterPasswordUnlockData: Data { payload.masterPasswordUnlockData }
  public var description: String { "PasswordSessionRecoveryRecord(<redacted>)" }
  public var debugDescription: String { description }

  public init(
    binding: PasswordAuthenticationBinding, identityURL: URL, apiURL: URL, serviceID: String,
    deviceID: UUID,
    clientID: String, email: String, sdkRevision: String, kdf: Data,
    wrappedAccountState: Data, masterPasswordUnlockData: Data,
    credential: PasswordCredential, revision: UInt64, state: State
  ) throws {
    guard let expiresAt = credential.expiresAt else { throw Error.malformed }
    let value = Payload(
      version: 2, profileID: binding.profileID, vaultID: binding.vaultID,
      accountID: binding.accountID, authority: binding.authority.absoluteString,
      identityURL: identityURL.absoluteString, apiURL: apiURL.absoluteString,
      serviceID: serviceID, deviceID: deviceID, clientID: clientID, email: email,
      sdkRevision: sdkRevision,
      kdf: kdf, wrappedAccountState: wrappedAccountState,
      masterPasswordUnlockData: masterPasswordUnlockData, accessToken: credential.accessToken,
      refreshToken: credential.refreshToken, expiresAt: expiresAt, revision: revision, state: state)
    try Self.validate(value)
    payload = value
  }

  public func belongs(to binding: PasswordAuthenticationBinding) -> Bool {
    payload.profileID == binding.profileID && payload.vaultID == binding.vaultID
      && payload.accountID == binding.accountID
      && payload.authority == binding.authority.absoluteString
  }

  public func replacing(
    credential: PasswordCredential, revision: UInt64, state: State
  ) throws -> PasswordSessionRecoveryRecord {
    try PasswordSessionRecoveryRecord(
      binding: PasswordAuthenticationBinding(
        profileID: payload.profileID, vaultID: payload.vaultID, accountID: payload.accountID,
        authority: URL(string: payload.authority)!),
      identityURL: identityURL, apiURL: apiURL, serviceID: serviceID, deviceID: deviceID,
      clientID: clientID, email: email, sdkRevision: sdkRevision, kdf: kdf,
      wrappedAccountState: wrappedAccountState, masterPasswordUnlockData: masterPasswordUnlockData,
      credential: credential, revision: revision, state: state)
  }

  public func encode() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    guard data.count <= Self.maxRecordBytes else { throw Error.tooLarge }
    return data
  }

  public static func decode(
    _ data: Data, binding: PasswordAuthenticationBinding, identityURL: URL, apiURL: URL,
    serviceID: String, deviceID: UUID, clientID: String, sdkRevision: String
  ) throws -> Self {
    guard data.count <= maxRecordBytes else { throw Error.tooLarge }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["version"] as? Int
    else { throw Error.malformed }
    guard version == 2 else { throw Error.unsupportedVersion }
    let allowed: Set<String> = [
      "version", "profileID", "vaultID", "accountID", "authority", "identityURL", "apiURL",
      "serviceID", "deviceID", "clientID", "email", "sdkRevision", "kdf", "wrappedAccountState",
      "masterPasswordUnlockData", "accessToken", "refreshToken", "expiresAt", "revision", "state",
    ]
    guard Set(object.keys).isSubset(of: allowed),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { throw Error.malformed }
    try validate(payload)
    guard payload.profileID == binding.profileID, payload.vaultID == binding.vaultID,
      payload.accountID == binding.accountID, payload.authority == binding.authority.absoluteString,
      payload.identityURL == identityURL.absoluteString, payload.apiURL == apiURL.absoluteString,
      payload.serviceID == serviceID, payload.deviceID == deviceID, payload.clientID == clientID,
      payload.sdkRevision == sdkRevision
    else { throw Error.bindingMismatch }
    let record = Self(payload: payload)
    guard try record.encode() == data else { throw Error.malformed }
    return record
  }

  private init(payload: Payload) { self.payload = payload }

  private static func validate(_ value: Payload) throws {
    func bounded(_ value: String, maximum: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= maximum
        && !value.unicodeScalars.contains { $0.value < 32 }
    }
    func validURL(_ value: String, authorityOnly: Bool = false) -> Bool {
      guard value.utf8.count <= 2048, let url = URL(string: value),
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        components.scheme == "https", let host = components.host, !host.isEmpty,
        components.user == nil, components.password == nil, components.query == nil,
        components.fragment == nil, components.port.map({ (1...65_535).contains($0) }) ?? true
      else { return false }
      return !authorityOnly || components.path.isEmpty || components.path == "/"
    }
    guard value.version == 2, validURL(value.authority, authorityOnly: true),
      validURL(value.identityURL), validURL(value.apiURL), bounded(value.serviceID, maximum: 2048),
      bounded(value.clientID, maximum: 256), bounded(value.email, maximum: 320),
      bounded(value.sdkRevision, maximum: 128), bounded(value.accessToken, maximum: 8192),
      value.refreshToken.map({ bounded($0, maximum: 8192) }) ?? true,
      value.expiresAt.timeIntervalSinceReferenceDate.isFinite,
      !value.kdf.isEmpty, value.kdf.count <= maxWrappedBytes,
      !value.wrappedAccountState.isEmpty, value.wrappedAccountState.count <= maxWrappedBytes,
      !value.masterPasswordUnlockData.isEmpty,
      value.masterPasswordUnlockData.count <= maxWrappedBytes
    else { throw Error.malformed }
  }
}
