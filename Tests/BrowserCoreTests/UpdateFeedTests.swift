import Foundation
import Testing

@testable import BrowserCore

private let feed = "https://arcusis.github.io/shaar/appcast.xml"
private let key = Data(repeating: 7, count: 32).base64EncodedString()

@Test func releaseBundleKeysEnableUpdateFeed() {
  #expect(UpdateFeed.isConfigured(in: ["SUFeedURL": feed, "SUPublicEDKey": key]))
}

@Test func developmentBundleWithoutFeedKeysStaysInert() {
  #expect(!UpdateFeed.isConfigured(in: [:]))
  #expect(!UpdateFeed.isConfigured(in: ["SUFeedURL": feed]))
  #expect(!UpdateFeed.isConfigured(in: ["SUPublicEDKey": key]))
}

@Test func placeholderOrMalformedPublicKeyKeepsUpdaterInert() {
  for candidate in [
    "SHAAR_SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER", "", Data(count: 31).base64EncodedString(),
    Data(count: 33).base64EncodedString(),
  ] {
    #expect(!UpdateFeed.isConfigured(in: ["SUFeedURL": feed, "SUPublicEDKey": candidate]))
  }
}

@Test func insecureOrMalformedFeedKeepsUpdaterInert() {
  for candidate in ["http://arcusis.github.io/shaar/appcast.xml", "appcast.xml", ""] {
    #expect(!UpdateFeed.isConfigured(in: ["SUFeedURL": candidate, "SUPublicEDKey": key]))
  }
}
