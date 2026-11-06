// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum DevelopmentFramework: String, CaseIterable, Sendable {
  case nextJS = "Next.js"
  case vite = "Vite"
  case angular = "Angular"
  case nuxt = "Nuxt"
  case remix = "Remix / React Router"
  case astro = "Astro"
  case svelteKit = "SvelteKit"
}

public struct DevelopmentPageMarkers: Sendable {
  public var responseHeaders: [String: String]
  public var resourcePaths: [String]
  public var documentMarkers: [String]

  public init(
    responseHeaders: [String: String] = [:], resourcePaths: [String] = [],
    documentMarkers: [String] = []
  ) {
    self.responseHeaders = responseHeaders
    self.resourcePaths = resourcePaths
    self.documentMarkers = documentMarkers
  }
}

public struct DevelopmentPage: Sendable {
  public let isDevelopmentPage: Bool
  public let detectedFramework: DevelopmentFramework?
  public let port: Int?

  public static func detect(url: URL, markers: DevelopmentPageMarkers = .init()) -> Self {
    guard isLocalDevelopmentURL(url) else {
      return Self(isDevelopmentPage: false, detectedFramework: nil, port: nil)
    }
    return Self(
      isDevelopmentPage: true, detectedFramework: detectFramework(markers), port: url.port)
  }

  private static func isLocalDevelopmentURL(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    else { return false }
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") {
      return true
    }
    if host == "::1" || host == "127.0.0.1" { return true }
    guard let port = url.port,
      [3000, 3001, 3333, 4000, 4200, 4321, 5000, 5173, 5174, 8000, 8080, 8081, 8888].contains(port)
    else { return false }
    let octets = host.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    if octets[0] == 10 || octets[0] == 192 && octets[1] == 168 { return true }
    return octets[0] == 172 && (16...31).contains(octets[1])
  }

  private static func detectFramework(_ markers: DevelopmentPageMarkers) -> DevelopmentFramework? {
    let headers = markers.responseHeaders.map { "\($0.key.lowercased()):\($0.value.lowercased())" }
    let resources = markers.resourcePaths.map { $0.lowercased() }
    let document = markers.documentMarkers.map { $0.lowercased() }
    func has(_ token: String, in values: [String]) -> Bool {
      values.contains { $0.contains(token) }
    }
    if has("next.js", in: headers) || has("/_next/", in: resources) || has("__next", in: document) {
      return .nextJS
    }
    if has("/@vite/client", in: resources) || has("vite", in: headers) { return .vite }
    if has("ng-version", in: document) || has("angular", in: headers) { return .angular }
    if has("/_nuxt/", in: resources) || has("__nuxt", in: document) { return .nuxt }
    if has("__remix", in: document) || has("react-router", in: document) { return .remix }
    if has("astro-island", in: document) || has("astro", in: headers) { return .astro }
    if has("_app/immutable", in: resources) || has("sveltekit", in: document) { return .svelteKit }
    return nil
  }
}
