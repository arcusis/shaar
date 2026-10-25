import ChromiumBridge
import CryptoKit
import Darwin
import Foundation

struct ProbeTLSConfiguration: Decodable {
  let schema: Int
  let spkiSHA256: String
  let certificateSHA256: String
  let matchedURL: URL
  let unmatchedURL: URL

  static func load(root: URL) throws -> Self {
    let directory = root.appending(path: "Chromium")
    var error: NSError?
    guard
      ARCProbeTLSArgument(
        directory, Data(repeating: 0, count: 32).base64EncodedString(), true, &error) != nil
    else { throw ProbeTLSFailure() }
    do {
      let metadata = try readOwned(root.appending(path: "probe-tls.json"))
      let configuration = try JSONDecoder().decode(
        Self.self, from: metadata)
      let tlsDirectory = root.appending(path: "vault-tls")
      var info = stat()
      guard lstat(tlsDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700,
        configuration.schema == 1,
        ARCProbeTLSArgument(directory, configuration.spkiSHA256, true, &error) != nil,
        valid(configuration.matchedURL), valid(configuration.unmatchedURL),
        configuration.matchedURL.port != configuration.unmatchedURL.port
      else { throw ProbeTLSFailure() }
      let certificate = try readOwned(tlsDirectory.appending(path: "certificate.pem"))
      let digest = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
      guard configuration.certificateSHA256 == digest else { throw ProbeTLSFailure() }
      return configuration
    } catch { throw ProbeTLSFailure() }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: StrictJSONKey.self)
    let expectedKeys: Set<String> = [
      "schema", "spkiSHA256", "certificateSHA256", "matchedURL", "unmatchedURL",
    ]
    guard Set(container.allKeys.map(\.stringValue)) == expectedKeys else {
      throw ProbeTLSFailure()
    }
    schema = try container.decode(Int.self, forKey: StrictJSONKey("schema"))
    spkiSHA256 = try container.decode(String.self, forKey: StrictJSONKey("spkiSHA256"))
    certificateSHA256 = try container.decode(
      String.self, forKey: StrictJSONKey("certificateSHA256"))
    matchedURL = try container.decode(URL.self, forKey: StrictJSONKey("matchedURL"))
    unmatchedURL = try container.decode(URL.self, forKey: StrictJSONKey("unmatchedURL"))
  }

  private static func valid(_ url: URL) -> Bool {
    url.scheme == "https" && url.host() == "127.0.0.1" && (1...65535).contains(url.port ?? 0)
      && url.user() == nil && url.password() == nil && url.query() == nil && url.fragment() == nil
      && ["/alive", "/icons/arcusis-fixture.invalid/icon.png"].contains(url.path())
  }

  private static func readOwned(_ url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw ProbeTLSFailure() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
      info.st_size > 0, info.st_size <= 65536,
      let data = try handle.read(upToCount: 65537), data.count == info.st_size
    else { throw ProbeTLSFailure() }
    return data
  }
}

struct StrictJSONKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}

struct ProbeTLSFailure: LocalizedError {
  var errorDescription: String? { "Invalid disposable TLS configuration or transport result." }
}
