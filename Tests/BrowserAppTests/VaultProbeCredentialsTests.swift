import ChromiumBridge
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct VaultProbeCredentialsTests {
  private let fingerprint = Data(repeating: 5, count: 32).base64EncodedString()

  private func fixture(certificate: Data = Data("certificate".utf8)) throws
    -> (URL, ProbeTLSConfiguration)
  {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arcusis-engine-probe-\(UUID().uuidString)"
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("arcusis-engine-probe-v1\n".utf8).write(to: root.appending(path: ".arcusis-probe"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: root.appending(path: ".arcusis-probe").path)
    let tlsRoot = root.appending(path: "vault-tls")
    try FileManager.default.createDirectory(
      at: tlsRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try certificate.write(to: tlsRoot.appending(path: "certificate.pem"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: tlsRoot.appending(path: "certificate.pem").path)
    let tlsObject: [String: Any] = [
      "schema": 1, "spkiSHA256": fingerprint,
      "certificateSHA256": SHA256.hash(data: certificate)
        .map { String(format: "%02x", $0) }.joined(),
      "matchedURL": "https://127.0.0.1:4443/alive",
      "unmatchedURL": "https://127.0.0.1:4444/alive",
    ]
    try write(tlsObject, to: root.appending(path: "probe-tls.json"), mode: 0o600)
    let tls = try ProbeTLSConfiguration.load(root: root)
    return (root, tls)
  }

  private func credentials(
    schema: Int = 1, serverURL: String = "https://127.0.0.1:4443",
    emails: [String] = ["alpha@arcusis-fixture.invalid", "beta@arcusis-fixture.invalid"],
    passwords: [String] = ["alpha-secret", "beta-secret"]
  ) -> [String: Any] {
    [
      "schema": schema, "serverURL": serverURL,
      "accounts": emails.enumerated().map { index, email in
        ["email": email, "masterPassword": passwords[index]]
      },
    ]
  }

  private func save(_ object: [String: Any], root: URL, mode: Int = 0o600) throws -> URL {
    let file = root.appending(path: "vault-credentials.json")
    try write(object, to: file, mode: mode)
    return file
  }

  private func write(_ object: [String: Any], to file: URL, mode: Int) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
  }

  @Test func acceptsExactLocalTLSOriginAndRedactsRepresentations() throws {
    let (root, tls) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try save(credentials(), root: root)
    let loaded = try VaultProbeCredentials.load(root: root, tls: tls)
    #expect(loaded.accounts.count == 2)
    #expect(loaded.description == "VaultProbeCredentials(<redacted>)")
    #expect(loaded.accounts[0].description == "VaultProbeCredentials.Account(<redacted>)")
  }

  @Test func rejectsSchemaOriginAccountsAndMalformedDocuments() throws {
    let (root, tls) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let invalid: [[String: Any]] = [
      credentials(schema: 2),
      credentials(serverURL: "https://127.0.0.1:4444"),
      credentials(serverURL: "https://user@127.0.0.1:4443"),
      credentials(serverURL: "http://127.0.0.1:4443"),
      credentials(emails: ["same@arcusis-fixture.invalid", "same@arcusis-fixture.invalid"]),
      credentials(emails: ["alpha@example.invalid", "beta@arcusis-fixture.invalid"]),
      credentials(
        emails: ["alpha@arcusis-fixture.invalid", "beta@arcusis-fixture.invalid"],
        passwords: ["", "secret"]),
    ]
    for object in invalid {
      _ = try save(object, root: root)
      #expect(throws: VaultProbeCredentialsFailure.self) {
        try VaultProbeCredentials.load(root: root, tls: tls)
      }
    }
    try Data("not-json-with-secret".utf8).write(to: root.appending(path: "vault-credentials.json"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: root.appending(path: "vault-credentials.json").path)
    do {
      _ = try VaultProbeCredentials.load(root: root, tls: tls)
      Issue.record("Expected malformed credentials to fail")
    } catch {
      #expect(error.localizedDescription == "Invalid Bitwarden vault probe credentials.")
      #expect(!error.localizedDescription.contains("secret"))
    }
  }

  @Test func rejectsUnownedLinkedPublicAndOversizedFiles() throws {
    let (root, tls) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try save(credentials(), root: root, mode: 0o644)
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: tls)
    }
    _ = try save(credentials(), root: root)
    let alias = root.appending(path: "credentials-link")
    try FileManager.default.linkItem(at: file, to: alias)
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: tls)
    }
    try FileManager.default.removeItem(at: alias)
    let oversized = root.appending(path: "vault-credentials.json")
    try Data(repeating: 0x41, count: 65537).write(to: oversized)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.path)
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: tls)
    }
  }

  @Test func rejectsCredentialSymlinkAndUnmarkedOrPublicRoot() throws {
    let (root, tls) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try save(credentials(), root: root)
    let alias = root.appending(path: "credentials-target")
    try FileManager.default.moveItem(at: file, to: alias)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alias)
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: tls)
    }
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: alias, to: file)
    try Data("wrong\n".utf8).write(to: root.appending(path: ".arcusis-probe"))
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: tls)
    }
    try Data("arcusis-engine-probe-v1\n".utf8).write(to: root.appending(path: ".arcusis-probe"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: tls)
    }
  }

  @Test func credentialsMustUseTLSConfigurationFromSameCanonicalRoot() throws {
    let (root, tls) = try fixture()
    let (otherRoot, otherTLS) = try fixture(certificate: Data("other-certificate".utf8))
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: otherRoot)
    }
    _ = try save(credentials(), root: root)
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: root, tls: otherTLS)
    }
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: otherRoot, tls: tls)
    }
    let alias = FileManager.default.temporaryDirectory.appending(path: "vault-root-alias-\(UUID())")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    defer { try? FileManager.default.removeItem(at: alias) }
    #expect(throws: VaultProbeCredentialsFailure.self) {
      try VaultProbeCredentials.load(root: alias, tls: tls)
    }
  }
}

@Test func vaultStageAcceptanceFailsClosedForMissingOrFailedRequiredStages() {
  let initialStages = [
    "store-consent", "onboarding-control", "signed-out-alpha", "signed-out-beta",
    "self-hosted-server-alpha", "self-hosted-server-beta", "account-alpha-login",
    "account-beta-login", "initial-locked-alpha", "initial-locked-beta",
    "initial-unlock-alpha", "initial-unlock-beta", "initial-restart-locked-alpha",
    "initial-restart-locked-beta",
    "account-alpha-identity-matches", "account-beta-identity-matches",
    "account-alpha-cross-profile-mismatch", "account-beta-cross-profile-mismatch",
    "shared-alpha-space-retains-profile", "separate-profile-isolation",
  ]
  let stages = Dictionary(uniqueKeysWithValues: initialStages.map { ($0, true) })
  #expect(VaultProbeStageAcceptance.accepts(phase: "initial", stages: stages))
  var failed = stages
  failed["initial-locked-beta"] = false
  #expect(!VaultProbeStageAcceptance.accepts(phase: "initial", stages: failed))
  var missing = stages
  missing["account-beta-cross-profile-mismatch"] = nil
  #expect(!VaultProbeStageAcceptance.accepts(phase: "initial", stages: missing))

  let restartStages = [
    "restart-locked-alpha", "restart-locked-beta", "restart-unlock-alpha",
    "restart-unlock-beta", "account-alpha-login", "account-beta-login",
    "account-alpha-identity-matches", "account-beta-identity-matches",
    "account-alpha-cross-profile-mismatch", "account-beta-cross-profile-mismatch",
    "shared-alpha-space-retains-profile", "separate-profile-isolation",
  ]
  #expect(
    VaultProbeStageAcceptance.accepts(
      phase: "restart", stages: Dictionary(uniqueKeysWithValues: restartStages.map { ($0, true) })))
  #expect(!VaultProbeStageAcceptance.accepts(phase: "unknown", stages: stages))
}
@Test func vaultFlagRequiresExistingOptInsAndRejectsAbruptModes() {
  #expect(
    BitwardenVaultFlags.valid(
      enabled: true, bitwarden: true, onboardingControl: true, fixtureTLS: true,
      awaitAbruptTermination: false, expectAbruptRecovery: false))
  #expect(
    !BitwardenVaultFlags.valid(
      enabled: true, bitwarden: false, onboardingControl: true, fixtureTLS: true,
      awaitAbruptTermination: false, expectAbruptRecovery: false))
  #expect(
    !BitwardenVaultFlags.valid(
      enabled: true, bitwarden: true, onboardingControl: false, fixtureTLS: true,
      awaitAbruptTermination: false, expectAbruptRecovery: false))
  #expect(
    !BitwardenVaultFlags.valid(
      enabled: true, bitwarden: true, onboardingControl: true, fixtureTLS: false,
      awaitAbruptTermination: false, expectAbruptRecovery: false))
  #expect(
    !BitwardenVaultFlags.valid(
      enabled: true, bitwarden: true, onboardingControl: true, fixtureTLS: true,
      awaitAbruptTermination: true, expectAbruptRecovery: false))
  #expect(
    !BitwardenVaultFlags.valid(
      enabled: true, bitwarden: true, onboardingControl: true, fixtureTLS: true,
      awaitAbruptTermination: false, expectAbruptRecovery: true))
  #expect(
    BitwardenVaultFlags.valid(
      enabled: false, bitwarden: false, onboardingControl: false, fixtureTLS: false,
      awaitAbruptTermination: false, expectAbruptRecovery: false))
}
