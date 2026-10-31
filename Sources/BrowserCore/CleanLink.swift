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
    let host = components.host?.lowercased() ?? ""
    let kept = components.queryItems?.filter { !isTracking($0.name.lowercased(), host: host) }
    components.queryItems = kept?.isEmpty == true ? nil : kept
    if isHost(host, in: ["amazon"]) {
      components.path = pathWithoutAmazonReferral(components.path)
    }
    return components.url ?? url
  }

  private static func isTracking(_ key: String, host: String) -> Bool {
    if key.hasPrefix("utm_") || trackingKeys.contains(key) { return true }
    if key == "si", isHost(host, in: ["youtube", "youtu", "spotify"]) { return true }
    if ["s", "t"].contains(key), isDomain(host, in: ["x.com", "twitter.com"]) { return true }
    if isHost(host, in: ["amazon"]) {
      return amazonTrackingKeys.contains(key)
        || amazonTrackingPrefixes.contains { key.hasPrefix($0) }
    }
    return false
  }

  /// Amazon appends `/ref=…` segments that only identify the click source.
  private static func pathWithoutAmazonReferral(_ path: String) -> String {
    let segments = path.split(separator: "/").filter { !$0.lowercased().hasPrefix("ref=") }
    return "/" + segments.joined(separator: "/")
  }

  private static func googleRedirectDestination(_ components: URLComponents) -> URL? {
    guard isDomain(components.host?.lowercased() ?? "", in: ["google.com"]),
      components.path == "/url",
      let value = components.queryItems?.first(where: { $0.name == "q" })?.value,
      let destination = URL(string: value),
      ["http", "https"].contains(destination.scheme?.lowercased() ?? "")
    else { return nil }
    return destination
  }

  /// True when any dot-separated label of the host is one of `names`, as in `www.amazon.co.uk`.
  private static func isHost(_ host: String, in names: Set<String>) -> Bool {
    host.split(separator: ".").contains { names.contains(String($0)) }
  }

  private static func isDomain(_ host: String, in domains: [String]) -> Bool {
    domains.contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}
