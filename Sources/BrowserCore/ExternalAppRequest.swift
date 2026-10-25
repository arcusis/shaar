import Foundation

/// An external-application prompt bound to the selected profile, tab, and web page.
public struct ExternalAppRequest: Identifiable, Equatable, Sendable {
  public let id: String
  public let profileID: UUID
  public let tabID: UUID
  public let pageURL: URL
  public let scheme: String
  public let requestingOrigin: URL?
  public let applicationName: String?
  public let windowID: String

  /// Whether an installed application can handle this scheme.
  public var canOpen: Bool { applicationName != nil }

  public init?(
    id: String, profileID: UUID, tabID: UUID, pageURL: URL, scheme: String,
    requestingOrigin: URL?, applicationName: String?, windowID: String
  ) {
    guard Self.isValidID(id), NavigationInput.isWebURL(pageURL),
      let normalizedScheme = Self.normalizedScheme(scheme),
      let normalizedOrigin = Self.normalizedOrigin(requestingOrigin),
      let normalizedApplicationName = Self.normalizedApplicationName(applicationName),
      Self.isValidWindowID(windowID)
    else { return nil }

    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.scheme = normalizedScheme
    self.requestingOrigin = normalizedOrigin
    self.applicationName = normalizedApplicationName
    self.windowID = windowID
  }

  public func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }

  private static func isValidID(_ id: String) -> Bool {
    let bytes = id.utf8
    guard (2...11).contains(bytes.count), bytes.first == 120,
      let firstDigit = bytes.dropFirst().first, firstDigit >= 49, firstDigit <= 57,
      bytes.dropFirst().allSatisfy({ $0 >= 48 && $0 <= 57 })
    else { return false }
    let value = bytes.dropFirst().reduce(Int64(0)) { value, digit in
      value * 10 + Int64(digit - 48)
    }
    return value <= Int64(Int32.max)
  }

  private static func normalizedScheme(_ scheme: String) -> String? {
    let bytes = scheme.utf8
    guard (1...64).contains(bytes.count),
      let first = bytes.first, isASCIILetter(first),
      bytes.dropFirst().allSatisfy({
        isASCIILetter($0) || (48...57).contains($0) || [43, 45, 46].contains($0)
      })
    else { return nil }

    let normalized = scheme.lowercased()
    let blocked = [
      "http", "https", "file", "data", "javascript", "chrome", "chrome-extension",
      "about", "devtools",
    ]
    return blocked.contains(normalized) ? nil : normalized
  }

  private static func normalizedOrigin(_ origin: URL?) -> URL?? {
    guard let origin else { return .some(nil) }
    guard NavigationInput.isWebURL(origin), origin.user == nil, origin.password == nil,
      origin.query == nil, origin.fragment == nil,
      origin.path.isEmpty || origin.path == "/",
      let source = URLComponents(url: origin, resolvingAgainstBaseURL: false),
      let scheme = source.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = source.host, !host.isEmpty
    else { return nil }

    var components = URLComponents()
    components.scheme = scheme
    components.host = host.lowercased()
    let port = source.port
    components.port =
      (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
      ? nil : port
    guard let normalized = components.url, NavigationInput.isWebURL(normalized) else { return nil }
    return .some(normalized)
  }

  private static func normalizedApplicationName(_ name: String?) -> String?? {
    guard let name else { return .some(nil) }
    guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= 256 else { return nil }
    return .some(trimmed.isEmpty ? nil : trimmed)
  }

  private static func isValidWindowID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 128
      && !id.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
          || CharacterSet.whitespacesAndNewlines.contains($0)
      })
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte)
  }
}
