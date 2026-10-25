import ChromiumBridge
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct ProbeTLSConfigurationTests {
  private let fingerprint = Data(repeating: 7, count: 32).base64EncodedString()

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arcusis-engine-probe-\(UUID().uuidString)"
    ).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("arcusis-engine-probe-v1\n".utf8).write(to: root.appending(path: ".arcusis-probe"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: root.appending(path: ".arcusis-probe").path)
    let tls = root.appending(path: "vault-tls")
    try FileManager.default.createDirectory(
      at: tls, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("public certificate fixture".utf8).write(to: tls.appending(path: "certificate.pem"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: tls.appending(path: "certificate.pem").path)
    try save(root: root)
    return root
  }

  private func save(root: URL, changes: [String: Any] = [:]) throws {
    var object: [String: Any] = [
      "schema": 1, "spkiSHA256": fingerprint,
      "certificateSHA256": SHA256.hash(data: Data("public certificate fixture".utf8))
        .map { String(format: "%02x", $0) }.joined(),
      "matchedURL": "https://127.0.0.1:4443/alive",
      "unmatchedURL": "https://127.0.0.1:4444/alive",
    ]
    object.merge(changes) { _, new in new }
    let file = root.appending(path: "probe-tls.json")
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  @Test func normalStartupNeverBuildsTLSException() {
    var error: NSError?
    #expect(ARCProbeTLSArgument(URL(filePath: "/does-not-exist"), nil, false, &error) == nil)
    #expect(error == nil)
    #expect(
      ARCProbeTLSArgument(URL(filePath: "/does-not-exist"), fingerprint, false, &error) == nil)
    #expect(error != nil)
  }

  @Test func exactKeyArgumentAndValidatedMetadata() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var error: NSError?
    #expect(
      ARCProbeTLSArgument(root.appending(path: "Chromium"), fingerprint, true, &error)
        == "--ignore-certificate-errors-spki-list=\(fingerprint)")
    #expect(error == nil)
    #expect(try ProbeTLSConfiguration.load(root: root).spkiSHA256 == fingerprint)
  }

  @Test func fixedAnonymousVaultImageIsAllowedButOtherResourcePathsAreRejected() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let address = "https://127.0.0.1:4443/icons/arcusis-fixture.invalid/icon.png"
    try save(root: root, changes: ["matchedURL": address])
    #expect(try ProbeTLSConfiguration.load(root: root).matchedURL.absoluteString == address)
    for path in [
      "/api/sync", "/icons/example.com/icon.png", "/icons/arcusis-fixture.invalid/icon.png?x=1",
    ] {
      try save(root: root, changes: ["matchedURL": "https://127.0.0.1:4443\(path)"])
      #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
    }
  }

  @Test func malformedOrMultipleKeysAndProductionModeFailClosed() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for value in [
      "", "invalid", fingerprint + "," + fingerprint, fingerprint + "\n",
      "--ignore-certificate-errors",
    ] {
      var error: NSError?
      #expect(ARCProbeTLSArgument(root.appending(path: "Chromium"), value, true, &error) == nil)
      #expect(error != nil)
    }
    var error: NSError?
    #expect(
      ARCProbeTLSArgument(root.appending(path: "Chromium"), fingerprint, false, &error) == nil)
    #expect(error != nil)
  }

  @Test func rejectsUnknownMetadataFields() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "probe-tls.json")
    let digest = SHA256.hash(data: Data("public certificate fixture".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let json =
      #"{"schema":1,"spkiSHA256":"\#(fingerprint)","certificateSHA256":"\#(digest)","matchedURL":"https://127.0.0.1:4443/alive","unmatchedURL":"https://127.0.0.1:4444/alive","unexpected":true}"#
    try Data(json.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
  }

  @Test func publicRootMarkerAndWrongDirectoryFailClosed() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var error: NSError?
    #expect(ARCProbeTLSArgument(root.appending(path: "Other"), fingerprint, true, &error) == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: root.appending(path: ".arcusis-probe").path)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
  }

  @Test func foreignURLsMismatchedCertificatesAndSchemasAreRejected() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for changes: [String: Any] in [
      ["matchedURL": "http://127.0.0.1:4443/alive"],
      ["matchedURL": "https://example.com:4443/alive"],
      ["matchedURL": "https://user@127.0.0.1:4443/alive"],
      ["matchedURL": "https://127.0.0.1:4443/alive?token=fixture"],
      ["matchedURL": "https://127.0.0.1:4443/other"],
      ["unmatchedURL": "https://127.0.0.1:4443/alive"],
      ["certificateSHA256": String(repeating: "0", count: 64)], ["schema": 2],
    ] {
      try save(root: root, changes: changes)
      #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
    }
  }

  @Test func linkedAndPublicMetadataAreRejected() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "probe-tls.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
    try save(root: root)
    let alias = root.appending(path: "metadata-link")
    try FileManager.default.linkItem(at: file, to: alias)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.moveItem(at: file, to: alias)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alias)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
  }

  @Test func rootDataAndCertificateSymlinksAreRejected() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.deletingLastPathComponent().appending(path: root.lastPathComponent + "-alias")
    defer { try? FileManager.default.removeItem(at: alias) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    var error: NSError?
    #expect(
      ARCProbeTLSArgument(alias.appending(path: "Chromium"), fingerprint, true, &error) == nil)
    let data = root.appending(path: "Chromium")
    try FileManager.default.createSymbolicLink(
      at: data, withDestinationURL: root.appending(path: "vault-tls"))
    #expect(ARCProbeTLSArgument(data, fingerprint, true, &error) == nil)
    try FileManager.default.removeItem(at: data)
    try FileManager.default.createSymbolicLink(atPath: data.path, withDestinationPath: data.path)
    #expect(ARCProbeTLSArgument(data, fingerprint, true, &error) == nil)
    try FileManager.default.removeItem(at: data)
    let certificate = root.appending(path: "vault-tls/certificate.pem")
    let saved = root.appending(path: "vault-tls/original.pem")
    try FileManager.default.moveItem(at: certificate, to: saved)
    try FileManager.default.createSymbolicLink(at: certificate, withDestinationURL: saved)
    #expect(throws: ProbeTLSFailure.self) { try ProbeTLSConfiguration.load(root: root) }
  }
}
