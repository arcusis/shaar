import Foundation

/// The Sparkle feed settings that only release bundles carry in Info.plist.
public enum UpdateFeed {
  /// True only for an HTTPS feed and a real 32-byte Ed25519 public key, so development
  /// bundles and placeholder keys never start the updater.
  public static func isConfigured(in infoDictionary: [String: Any]) -> Bool {
    guard let feed = infoDictionary["SUFeedURL"] as? String,
      let feedURL = URL(string: feed), feedURL.scheme == "https", feedURL.host() != nil,
      let publicEDKey = infoDictionary["SUPublicEDKey"] as? String
    else { return false }
    return Data(base64Encoded: publicEDKey)?.count == 32
  }
}
