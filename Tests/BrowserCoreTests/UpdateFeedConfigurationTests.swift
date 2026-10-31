import Foundation
import Testing

@testable import BrowserCore

private let feed = "https://arcusis.github.io/shaar/appcast.xml"
private let key = Data(repeating: 7, count: 32).base64EncodedString()

@Test func releaseBundleKeysEnableUpdateFeed() throws {
  let configuration = try #require(
    UpdateFeedConfiguration(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": key]))
  #expect(configuration.feedURL.absoluteString == feed)
  #expect(configuration.publicEDKey == key)
}

@Test func developmentBundleWithoutFeedKeysStaysInert() {
  #expect(UpdateFeedConfiguration(infoDictionary: [:]) == nil)
  #expect(UpdateFeedConfiguration(infoDictionary: ["SUFeedURL": feed]) == nil)
  #expect(UpdateFeedConfiguration(infoDictionary: ["SUPublicEDKey": key]) == nil)
}

@Test func placeholderOrMalformedPublicKeyKeepsUpdaterInert() {
  for candidate in [
    "SHAAR_SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER", "", Data(count: 31).base64EncodedString(),
    Data(count: 33).base64EncodedString(),
  ] {
    #expect(
      UpdateFeedConfiguration(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": candidate])
        == nil)
  }
}

@Test func insecureOrMalformedFeedKeepsUpdaterInert() {
  for candidate in ["http://arcusis.github.io/shaar/appcast.xml", "appcast.xml", ""] {
    #expect(
      UpdateFeedConfiguration(infoDictionary: ["SUFeedURL": candidate, "SUPublicEDKey": key])
        == nil)
  }
}
