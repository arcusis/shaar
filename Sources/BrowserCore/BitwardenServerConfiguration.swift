import Foundation

public enum BitwardenServerRegion: String, Codable, CaseIterable, Sendable {
  case us
  case eu
  case custom
}

public struct BitwardenServiceEndpoints: Equatable, Sendable {
  public let apiURL: URL
  public let identityURL: URL
  public let credentialAuthority: URL
  public let stableServiceID: String
}

public enum BitwardenServerConfigurationError: Error, Equatable, Sendable {
  case customURLRequired
  case invalidCustomURL
}

/// Bitwarden endpoints selected by the user. Custom URLs name service base, not API endpoint.
public struct BitwardenServerConfiguration: Codable, Equatable, Sendable {
  public let region: BitwardenServerRegion
  public let customBaseURL: String?

  public init(region: BitwardenServerRegion, customBaseURL: String? = nil) {
    self.region = region
    self.customBaseURL = customBaseURL
  }

  public func endpoints() throws -> BitwardenServiceEndpoints {
    switch region {
    case .us:
      return BitwardenServiceEndpoints(
        apiURL: URL(string: "https://api.bitwarden.com")!,
        identityURL: URL(string: "https://identity.bitwarden.com")!,
        credentialAuthority: URL(string: "https://api.bitwarden.com")!,
        stableServiceID: "bitwarden-us")
    case .eu:
      return BitwardenServiceEndpoints(
        apiURL: URL(string: "https://api.bitwarden.eu")!,
        identityURL: URL(string: "https://identity.bitwarden.eu")!,
        credentialAuthority: URL(string: "https://api.bitwarden.eu")!,
        stableServiceID: "bitwarden-eu")
    case .custom:
      guard let customBaseURL, !customBaseURL.isEmpty else {
        throw BitwardenServerConfigurationError.customURLRequired
      }
      guard customBaseURL.utf8.count <= 2_048,
        let components = URLComponents(string: customBaseURL),
        components.scheme?.lowercased() == "https",
        let host = components.host?.lowercased(), !host.isEmpty,
        components.user == nil, components.password == nil,
        components.query == nil, components.fragment == nil,
        components.port.map({ (1...65_535).contains($0) }) ?? true,
        !components.percentEncodedPath.split(separator: "/").contains(where: {
          $0 == "." || $0 == ".." || $0.lowercased() == "%2e" || $0.lowercased() == "%2e%2e"
        })
      else {
        throw BitwardenServerConfigurationError.invalidCustomURL
      }
      var base = components
      base.scheme = "https"
      base.host = host
      var basePath = base.path
      while basePath.first == "/" { basePath.removeFirst() }
      while basePath.last == "/" { basePath.removeLast() }
      base.path = basePath.isEmpty ? "" : "/" + basePath
      base.query = nil
      base.fragment = nil
      guard let baseURL = base.url else { throw BitwardenServerConfigurationError.invalidCustomURL }

      var api = base
      api.path = base.path + "/api"
      var identity = base
      identity.path = base.path + "/identity"
      guard let apiURL = api.url, let identityURL = identity.url else {
        throw BitwardenServerConfigurationError.invalidCustomURL
      }
      var authority = URLComponents()
      authority.scheme = "https"
      authority.host = host
      authority.port = components.port
      guard let authorityURL = authority.url else {
        throw BitwardenServerConfigurationError.invalidCustomURL
      }
      return BitwardenServiceEndpoints(
        apiURL: apiURL, identityURL: identityURL, credentialAuthority: authorityURL,
        stableServiceID: baseURL.absoluteString)
    }
  }
}
