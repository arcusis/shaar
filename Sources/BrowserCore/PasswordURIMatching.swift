import CryptoKit
import Darwin
import Foundation

/// A nil item strategy uses the account default, falling back to domain.
public enum PasswordURIMatchStrategy: Sendable {
  case domain, host, startsWith, exact, regularExpression, never
}

public enum PasswordURIMatchResult: Equatable, Sendable {
  case match, noMatch, unsupportedRegularExpression
}

private final class PasswordResourceBundleFinder {}

enum PasswordResourceFailure: Error {
  case missingBundle, invalidBundle, missingData, invalidData, hashMismatch, invalidUTF8,
    invalidPolicy
}

/// Immutable public-suffix rules. Invalid or incomplete data never produces a policy.
public struct PasswordPublicSuffixList: Sendable {
  private let exact: Set<String>
  private let wildcard: Set<String>
  private let exceptions: Set<String>
  private static let expectedHash =
    "4155611645690529d1bbea0cfe653b0c45f63b028e0ba039de29a97edc3204ca"

  public static func bundled() -> PasswordPublicSuffixList? {
    try? bundledResult().get()
  }

  static func bundledResult() -> Result<PasswordPublicSuffixList, PasswordResourceFailure> {
    let main = Bundle.main
    return loadBundledResourceResult(
      from: resourceRoots(
        mainBundleURL: main.bundleURL, mainResourceURL: main.resourceURL,
        mainExecutableURL: main.executableURL,
        codeResourceURL: Bundle(for: PasswordResourceBundleFinder.self).resourceURL,
        loadedBundleURLs: Bundle.allBundles.map(\.bundleURL)))
  }

  static func resourceRoots(
    mainBundleURL: URL, mainResourceURL: URL?, mainExecutableURL: URL?,
    codeResourceURL: URL?, loadedBundleURLs: [URL]
  ) -> [URL] {
    var roots = [mainResourceURL, codeResourceURL, mainBundleURL].compactMap { $0 }
    // Classic SwiftPM places resources beside the loaded XCTest bundle. Swift Testing
    // uses its own helper to load that bundle instead of the xctest executable.
    // Never search app siblings, even if an app happens to load test bundles.
    if mainBundleURL.pathExtension != "app",
      let executableName = mainExecutableURL?.lastPathComponent,
      ["xctest", "swiftpm-testing-helper"].contains(executableName)
    {
      roots += loadedBundleURLs.filter { $0.pathExtension == "xctest" }.map {
        $0.deletingLastPathComponent()
      }
    }
    return roots
  }

  // Roots are supplied explicitly so tests can exercise relocated and damaged bundles.
  static func loadBundledResource(from roots: [URL]) -> PasswordPublicSuffixList? {
    try? loadBundledResourceResult(from: roots).get()
  }

  static func loadBundledResourceResult(from roots: [URL])
    -> Result<PasswordPublicSuffixList, PasswordResourceFailure>
  {
    for root in roots {
      let bundleURL = root.appendingPathComponent("ArcusisBrowser_BrowserCore.bundle")
      guard FileManager.default.fileExists(atPath: bundleURL.path) else { continue }
      guard let bundle = Bundle(url: bundleURL) else { return .failure(.invalidBundle) }
      guard let url = bundle.url(forResource: "public_suffix_list", withExtension: "dat") else {
        return .failure(.missingData)
      }
      guard let data = boundedResourceData(at: url) else { return .failure(.invalidData) }
      guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash
      else { return .failure(.hashMismatch) }
      guard let text = String(data: data, encoding: .utf8) else { return .failure(.invalidUTF8) }
      guard let policy = PasswordPublicSuffixList(contents: text) else {
        return .failure(.invalidPolicy)
      }
      return .success(policy)
    }
    return .failure(.missingBundle)
  }

  private static func boundedResourceData(at url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 2_000_001), data.count <= 2_000_000 else {
      return nil
    }
    return data
  }

  /// Useful for testing and independently pinned rule sets; requires both complete sections.
  public init?(contents: String) {
    guard contents.utf8.count <= 2_000_000 else { return nil }
    var exact = Set<String>()
    var wildcard = Set<String>()
    var exceptions = Set<String>()
    var section = 0
    for raw in contents.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      switch line {
      case "// ===BEGIN ICANN DOMAINS===":
        guard section == 0 else { return nil }
        section = 1
      case "// ===END ICANN DOMAINS===":
        guard section == 1 else { return nil }
        section = 2
      case "// ===BEGIN PRIVATE DOMAINS===":
        guard section == 2 else { return nil }
        section = 3
      case "// ===END PRIVATE DOMAINS===":
        guard section == 3 else { return nil }
        section = 4
      default:
        if line.isEmpty || line.hasPrefix("//") { continue }
        guard section == 1 || section == 3 else { return nil }
        let isException = line.hasPrefix("!")
        let isWildcard = line.hasPrefix("*.")
        let rule =
          isException ? String(line.dropFirst()) : (isWildcard ? String(line.dropFirst(2)) : line)
        guard let host = normalizedDNSHost(rule), !host.hasSuffix("."),
          host.contains(".") || !isException,
          !host.contains("*")
        else { return nil }
        if isException {
          exceptions.insert(host)
        } else if isWildcard {
          wildcard.insert(host)
        } else {
          exact.insert(host)
        }
      }
    }
    guard section == 4, !exact.isEmpty else { return nil }
    self.exact = exact
    self.wildcard = wildcard
    self.exceptions = exceptions
  }

  fileprivate func domain(for host: String) -> String? {
    let hostname = host.hasSuffix(".") ? String(host.dropLast()) : host
    if hostname == "localhost" { return "localhost" }
    if isIP(hostname) { return hostname }
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count > 1, !labels.contains("") else { return nil }
    var suffixLength = 1
    var exceptionLength: Int?
    for index in labels.indices {
      let candidate = labels[index...].joined(separator: ".")
      let count = labels.count - index
      if exceptions.contains(candidate) { exceptionLength = max(exceptionLength ?? 0, count - 1) }
      if exact.contains(candidate) { suffixLength = max(suffixLength, count) }
      if index > 0 && wildcard.contains(candidate) { suffixLength = max(suffixLength, count + 1) }
    }
    if let exceptionLength { suffixLength = exceptionLength }
    guard labels.count > suffixLength else { return nil }
    return labels.suffix(suffixLength + 1).joined(separator: ".")
  }
}

private func isIP(_ host: String) -> Bool {
  var v4 = in_addr()
  var v6 = in6_addr()
  if host.hasPrefix("[") && host.hasSuffix("]") {
    return inet_pton(AF_INET6, String(host.dropFirst().dropLast()), &v6) == 1
  }
  return inet_pton(AF_INET, host, &v4) == 1
}

/// Foundation serializes internationalized hosts to ASCII; validate every resulting label.
func normalizedDNSHost(_ host: String) -> String? {
  guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0.isNewline }),
    !host.contains(where: { "/:@?#%\\[]".contains($0) }),
    let url = URL(string: "https://" + host),
    let authority = url.absoluteString.split(separator: "/", omittingEmptySubsequences: true).last
  else { return nil }
  let ascii = String(authority).lowercased()
  let trimmed = ascii.hasSuffix(".") ? String(ascii.dropLast()) : ascii
  guard trimmed.utf8.count <= 253, !trimmed.isEmpty else { return nil }
  for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
    guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-",
      label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
    else { return nil }
  }
  return ascii
}

private func validPercentEscapes(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  var index = 0
  func hex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
  }
  while index < bytes.count {
    if bytes[index] == 37 {
      guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else {
        return false
      }
      index += 3
    } else {
      index += 1
    }
  }
  return true
}

private struct SavedWebURI {
  let host: String
  let port: Int?

  init?(_ value: String) {
    guard !value.isEmpty, value.utf8.count <= 8192,
      !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 || $0.value == 92 }),
      validPercentEscapes(value)
    else { return nil }
    let candidate = value.contains("://") ? value : "http://" + value
    guard let parts = URLComponents(string: candidate),
      let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
      parts.user == nil, parts.password == nil, let originalHost = parts.host,
      !originalHost.isEmpty,
      parts.port.map({ (1...65535).contains($0) }) ?? true
    else { return nil }
    let port = parts.port
    let host: String
    if originalHost.hasPrefix("[") {
      guard isIP(originalHost.lowercased()) else { return nil }
      var binary = in6_addr()
      var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      guard inet_pton(AF_INET6, String(originalHost.dropFirst().dropLast()), &binary) == 1,
        inet_ntop(AF_INET6, &binary, &output, socklen_t(output.count)) != nil
      else { return nil }
      host =
        "["
        + String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        + "]"
    } else {
      guard let normalized = normalizedDNSHost(originalHost) else { return nil }
      host = normalized
      let last = host.split(separator: ".").last ?? ""
      if last.utf8.allSatisfy({ (48...57).contains($0) }) && !isIP(host) { return nil }
    }
    self.host = host
    self.port = (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? nil : port
  }
}

/// Pure matching policy; callers supply only native-validated context and account defaults.
public struct PasswordURIMatching: Sendable {
  private let suffixes: PasswordPublicSuffixList

  public init(suffixes: PasswordPublicSuffixList) { self.suffixes = suffixes }

  public func match(
    savedURI: String, strategy: PasswordURIMatchStrategy? = nil,
    defaultStrategy: PasswordURIMatchStrategy? = nil, context: PasswordFillContext
  ) -> PasswordURIMatchResult {
    let mode = strategy ?? defaultStrategy ?? .domain
    if mode == .never { return .noMatch }
    if mode == .regularExpression { return .unsupportedRegularExpression }
    guard let saved = SavedWebURI(savedURI), let target = SavedWebURI(context.origin.value),
      context.documentURL.map({ $0.origin == context.origin }) ?? true
    else { return .noMatch }
    switch mode {
    case .domain:
      guard let savedDomain = suffixes.domain(for: saved.host),
        let targetDomain = suffixes.domain(for: target.host), savedDomain == targetDomain
      else { return .noMatch }
      if savedDomain == "google.com" && target.host == "script.google.com" && target.port == nil {
        return .noMatch
      }
      return .match
    case .host:
      guard savedURI.contains("://") || savedURI.contains(".") else { return .noMatch }
      return saved.host == target.host && saved.port == target.port ? .match : .noMatch
    case .exact, .startsWith:
      guard let document = context.documentURL else { return .noMatch }
      let matches = mode == .exact ? document.value == savedURI : document.value.hasPrefix(savedURI)
      return matches ? .match : .noMatch
    case .never, .regularExpression:
      return .noMatch
    }
  }
}
