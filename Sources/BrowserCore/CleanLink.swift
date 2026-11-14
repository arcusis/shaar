// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Removes tracking from a link before it is shared, keeping the parameters a page needs.
public enum CleanLink {
  private static let trackingKeys: Set<String> = [
    "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igsh",
    "igshid",
  ]
  private static let amazonTrackingKeys: Set<String> = ["ref", "tag", "psc", "content-id"]
  private static let amazonTrackingPrefixes = ["ref_", "pd_rd_", "pf_rd_"]

  public static func clean(_ url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    if let destination = googleRedirectDestination(components) {
      return clean(destination)
    }
    let hasCredentials = components.user != nil || components.password != nil
    let host = components.host?.lowercased() ?? ""
    let kept = components.queryItems?.filter { !isTracking($0.name.lowercased(), host: host) }
    let cleanedPath =
      isAmazonDomain(host) ? pathWithoutAmazonReferral(components.path) : components.path
    if kept?.count == components.queryItems?.count && cleanedPath == components.path
      && !hasCredentials
    {
      return url
    }
    components.user = nil
    components.password = nil
    if kept?.count != components.queryItems?.count {
      components.queryItems = kept?.isEmpty == true ? nil : kept
    }
    if cleanedPath != components.path { components.path = cleanedPath }
    return components.url ?? url
  }

  private static func isTracking(_ key: String, host: String) -> Bool {
    if key.hasPrefix("utm_") || trackingKeys.contains(key) { return true }
    if key == "si", isDomain(host, in: ["youtube.com", "youtu.be", "spotify.com"]) {
      return true
    }
    if ["s", "t"].contains(key), isDomain(host, in: ["x.com", "twitter.com"]) { return true }
    if isAmazonDomain(host) {
      return amazonTrackingKeys.contains(key)
        || amazonTrackingPrefixes.contains { key.hasPrefix($0) }
    }
    return false
  }

  /// Amazon appends `/ref=…` segments that only identify the click source.
  private static func pathWithoutAmazonReferral(_ path: String) -> String {
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
      .filter { !$0.lowercased().hasPrefix("ref=") }
    return segments.joined(separator: "/")
  }

  private static func googleRedirectDestination(_ components: URLComponents) -> URL? {
    guard isGoogleDomain(components.host?.lowercased() ?? ""),
      components.path == "/url",
      let value = components.queryItems?.first(where: { $0.name == "q" })?.value,
      let destination = URL(string: value),
      NavigationInput.isWebURL(destination)
    else { return nil }
    return destination
  }

  private static func isGoogleDomain(_ host: String) -> Bool {
    let labels = host.split(separator: ".")
    guard let last = labels.last, labels.count >= 2 else { return false }
    let previous = labels[labels.count - 2]
    if previous == "google" { return last == "com" || last.count == 2 }
    return labels.count >= 3 && labels[labels.count - 3] == "google"
      && (previous == "co" || previous == "com") && last.count == 2
  }

  /// True when any dot-separated label of the host is one of `names`, as in `www.amazon.co.uk`.
  private static func isHost(_ host: String, in names: Set<String>) -> Bool {
    host.split(separator: ".").contains { names.contains(String($0)) }
  }

  private static func isAmazonDomain(_ host: String) -> Bool {
    let labels = host.split(separator: ".")
    guard let amazon = labels.lastIndex(of: "amazon") else { return false }
    let suffix = Array(labels[(amazon + 1)...])
    if suffix.count == 1 { return suffix[0] == "com" || suffix[0].count == 2 }
    return suffix.count == 2 && ["co", "com"].contains(suffix[0]) && suffix[1].count == 2
  }

  private static func isDomain(_ host: String, in domains: [String]) -> Bool {
    domains.contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}
