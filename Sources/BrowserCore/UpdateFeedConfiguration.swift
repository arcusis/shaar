import Foundation

/// Sparkle feed settings that only release bundles carry in Info.plist.
public struct UpdateFeedConfiguration: Equatable, Sendable {
  public let feedURL: URL
  public let publicEDKey: String

  /// Returns nil unless the bundle names an HTTPS feed and a real Ed25519 public key, so
  /// development bundles and placeholder keys never start the updater.
  public init?(infoDictionary: [String: Any]) {
    guard let feed = infoDictionary["SUFeedURL"] as? String,
      let feedURL = URL(string: feed), feedURL.scheme == "https", feedURL.host() != nil,
      let publicEDKey = infoDictionary["SUPublicEDKey"] as? String,
      Data(base64Encoded: publicEDKey)?.count == 32
    else { return nil }
    self.feedURL = feedURL
    self.publicEDKey = publicEDKey
  }
}
