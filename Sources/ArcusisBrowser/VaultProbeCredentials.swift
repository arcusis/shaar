import Darwin
import Foundation

struct VaultProbeCredentials: CustomStringConvertible, CustomDebugStringConvertible {
  struct Account: CustomStringConvertible, CustomDebugStringConvertible {
    let email: String
    let masterPassword: String
    var description: String { "VaultProbeCredentials.Account(<redacted>)" }
    var debugDescription: String { description }
  }

  let serverURL: URL
  let accounts: [Account]
  var description: String { "VaultProbeCredentials(<redacted>)" }
  var debugDescription: String { description }

  static func load(root: URL, tls: ProbeTLSConfiguration) throws -> Self {
    do {
      let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
      let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        .resolvingSymlinksInPath()
      let currentTLS = try ProbeTLSConfiguration.load(root: canonicalRoot)
      var rootInfo = stat()
      guard root.isFileURL, canonicalRoot.path.hasPrefix(temporaryRoot.path + "/"),
        canonicalRoot.path == root.standardizedFileURL.path,
        lstat(canonicalRoot.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
        rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o7777 == 0o700,
        try readOwned(canonicalRoot.appending(path: ".arcusis-probe"))
          == Data("arcusis-engine-probe-v1\n".utf8),
        sameTLSConfiguration(tls, currentTLS)
      else { throw VaultProbeCredentialsFailure() }
      let data = try readOwned(canonicalRoot.appending(path: "vault-credentials.json"))
      let raw = try JSONDecoder().decode(Document.self, from: data)
      guard raw.schema == 1, let serverURL = URL(string: raw.serverURL),
        validOrigin(serverURL), sameOrigin(serverURL, tls.matchedURL), raw.accounts.count == 2,
        raw.accounts.allSatisfy({
          validEmail($0.email) && !$0.masterPassword.isEmpty
            && $0.masterPassword.utf8.count <= 4096
        }),
        raw.accounts[0].email.caseInsensitiveCompare(raw.accounts[1].email) != .orderedSame
      else { throw VaultProbeCredentialsFailure() }
      return Self(
        serverURL: serverURL,
        accounts: raw.accounts.map { Account(email: $0.email, masterPassword: $0.masterPassword) })
    } catch { throw VaultProbeCredentialsFailure() }
  }

  private static func readOwned(_ url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw VaultProbeCredentialsFailure() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
      info.st_size > 0, info.st_size <= 65536,
      let data = try handle.read(upToCount: 65537), data.count == info.st_size
    else { throw VaultProbeCredentialsFailure() }
    return data
  }

  private static func validOrigin(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host()?.lowercased() == "127.0.0.1"
      && (1...65535).contains(url.port ?? 443) && url.user() == nil && url.password() == nil
      && url.query() == nil && url.fragment() == nil
  }

  private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host()?.lowercased() == rhs.host()?.lowercased()
      && (lhs.port ?? 443) == (rhs.port ?? 443)
  }

  private static func sameTLSConfiguration(
    _ lhs: ProbeTLSConfiguration, _ rhs: ProbeTLSConfiguration
  ) -> Bool {
    lhs.schema == rhs.schema && lhs.spkiSHA256 == rhs.spkiSHA256
      && lhs.certificateSHA256 == rhs.certificateSHA256
      && lhs.matchedURL == rhs.matchedURL && lhs.unmatchedURL == rhs.unmatchedURL
  }

  private static func validEmail(_ value: String) -> Bool {
    let components = value.split(separator: "@", omittingEmptySubsequences: false)
    guard components.count == 2, components[1].lowercased() == "arcusis-fixture.invalid",
      (1...64).contains(components[0].utf8.count)
    else { return false }
    return components[0].allSatisfy {
      $0.isASCII && ($0.isLetter || $0.isNumber || "._-+".contains($0))
    }
  }

  private struct Document: Decodable {
    let schema: Int
    let serverURL: String
    let accounts: [RawAccount]

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: StrictJSONKey.self)
      let expectedKeys: Set<String> = ["schema", "serverURL", "accounts"]
      guard Set(container.allKeys.map(\.stringValue)) == expectedKeys else {
        throw VaultProbeCredentialsFailure()
      }
      schema = try container.decode(Int.self, forKey: StrictJSONKey("schema"))
      serverURL = try container.decode(String.self, forKey: StrictJSONKey("serverURL"))
      accounts = try container.decode([RawAccount].self, forKey: StrictJSONKey("accounts"))
    }
  }

  private struct RawAccount: Decodable {
    let email: String
    let masterPassword: String

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: StrictJSONKey.self)
      let expectedKeys: Set<String> = ["email", "masterPassword"]
      guard Set(container.allKeys.map(\.stringValue)) == expectedKeys else {
        throw VaultProbeCredentialsFailure()
      }
      email = try container.decode(String.self, forKey: StrictJSONKey("email"))
      masterPassword = try container.decode(String.self, forKey: StrictJSONKey("masterPassword"))
    }
  }
}

struct VaultProbeCredentialsFailure: LocalizedError {
  var errorDescription: String? { "Invalid Bitwarden vault probe credentials." }
}
