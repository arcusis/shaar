import Darwin
import Foundation

private func canonicalIPHost(_ host: String) -> Bool {
  if host.hasPrefix("[") && host.hasSuffix("]") {
    let address = String(host.dropFirst().dropLast())
    var binary = in6_addr()
    var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_pton(AF_INET6, address, &binary) == 1,
      inet_ntop(AF_INET6, &binary, &output, socklen_t(output.count)) != nil
    else { return false }
    return "[" + String(cString: output) + "]" == host
  }
  let last = host.split(separator: ".", omittingEmptySubsequences: false).last ?? ""
  let candidate = last.isEmpty ? host.dropLast().split(separator: ".").last ?? "" : last
  let decimal = !candidate.isEmpty && candidate.utf8.allSatisfy { (48...57).contains($0) }
  let hexadecimal =
    candidate.hasPrefix("0x")
    && candidate.dropFirst(2).utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  guard decimal || hexadecimal else { return true }
  var binary = in_addr()
  var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  guard inet_pton(AF_INET, host, &binary) == 1,
    inet_ntop(AF_INET, &binary, &output, socklen_t(output.count)) != nil
  else { return false }
  return String(cString: output) == host
}

/// Exact host ownership, supplied by the trusted native caller.
public struct PasswordFillBinding: Equatable, Sendable {
  public let windowID: UUID
  public let profileID: UUID
  public let tabID: UUID

  public init(windowID: UUID, profileID: UUID, tabID: UUID) {
    self.windowID = windowID
    self.profileID = profileID
    self.tabID = tabID
  }
}

/// Origin serialized by the native engine; never a URL with a path or credentials.
public struct PasswordFillOrigin: Equatable, Sendable {
  public let value: String

  public init?(_ value: String) {
    guard let parts = URLComponents(string: value), parts.scheme == "https",
      let host = parts.host, !host.isEmpty, host == host.lowercased(),
      let encodedHost = parts.percentEncodedHost, !encodedHost.contains("%"),
      canonicalIPHost(encodedHost),
      parts.user == nil, parts.password == nil, parts.path.isEmpty,
      parts.query == nil, parts.fragment == nil,
      parts.port.map({ (1...65535).contains($0) && $0 != 443 }) ?? true,
      value == "https://" + encodedHost + (parts.port.map { ":\($0)" } ?? ""), parts.url != nil
    else { return nil }
    self.value = value
  }
}

/// Serialized URL supplied by the native request, retained exactly for lease identity.
public struct PasswordFillDocumentURL: Equatable, Sendable {
  public let value: String
  public let origin: PasswordFillOrigin

  public init?(_ value: String, origin: PasswordFillOrigin) {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 8192,
      bytes.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
      value.hasPrefix(origin.value)
    else { return nil }
    let suffix = value.dropFirst(origin.value.count)
    guard suffix.first.map({ ["/", "?", "#"].contains($0) }) ?? true,
      let parts = URLComponents(string: value, encodingInvalidCharacters: false),
      parts.scheme == "https", parts.user == nil, parts.password == nil,
      parts.url?.absoluteString == value
    else { return nil }
    self.value = value
    self.origin = origin
  }
}

public struct PasswordFillContext: Equatable, Sendable {
  public let requestID: UUID
  public let binding: PasswordFillBinding
  public let origin: PasswordFillOrigin
  public let documentURL: PasswordFillDocumentURL?

  public init(
    requestID: UUID, binding: PasswordFillBinding, origin: PasswordFillOrigin,
    documentURL: PasswordFillDocumentURL? = nil
  ) {
    self.requestID = requestID
    self.binding = binding
    self.origin = origin
    self.documentURL = documentURL
  }
}

/// Caller supplies monotonic time; consuming is one-use and checks current ownership.
@MainActor
public final class PasswordFillLease {
  public let context: PasswordFillContext
  public let deadline: TimeInterval
  private var consumed = false

  public init(context: PasswordFillContext, deadline: TimeInterval) {
    self.context = context
    self.deadline = deadline
  }

  public func consume(
    context: PasswordFillContext, binding: PasswordFillBinding?, now: TimeInterval
  ) -> Bool {
    guard !consumed, self.context == context, binding == context.binding,
      context.documentURL.map({ $0.origin == context.origin }) ?? true,
      now.isFinite, deadline.isFinite, now < deadline
    else { return false }
    consumed = true
    return true
  }
}
