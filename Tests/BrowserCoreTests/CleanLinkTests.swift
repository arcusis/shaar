import BrowserCore
import Foundation
import Testing

@Test func cleanLinkRemovesAmazonTracking() {
  let input = URL(
    string: "https://www.amazon.com/dp/B012345678/ref=abc?tag=store&psc=1&pd_rd_x=2&color=blue")!
  #expect(
    CleanLink.clean(input).absoluteString == "https://www.amazon.com/dp/B012345678?color=blue")
}

@Test func cleanLinkRemovesSocialTrackingAndPreservesPageParameters() {
  #expect(
    CleanLink.clean(URL(string: "https://www.instagram.com/p/abc/?igsh=one&utm_source=x")!)
      .absoluteString
      == "https://www.instagram.com/p/abc/"
  )
  #expect(
    CleanLink.clean(URL(string: "https://x.com/user/status/123?s=20&t=abc&view=full")!)
      .absoluteString
      == "https://x.com/user/status/123?view=full"
  )
  #expect(
    CleanLink.clean(URL(string: "https://www.tiktok.com/@user/video/123?fbclid=abc")!)
      .absoluteString
      == "https://www.tiktok.com/@user/video/123"
  )
  #expect(
    CleanLink.clean(URL(string: "https://www.linkedin.com/posts/user_123?utm_campaign=abc")!)
      .absoluteString
      == "https://www.linkedin.com/posts/user_123"
  )
}

@Test func cleanLinkPreservesYouTubeParametersAndCleansShortLinks() {
  #expect(
    CleanLink.clean(URL(string: "https://www.youtube.com/watch?v=video&t=42s&si=share")!)
      .absoluteString
      == "https://www.youtube.com/watch?v=video&t=42s"
  )
  #expect(
    CleanLink.clean(URL(string: "https://youtu.be/video?si=share")!).absoluteString
      == "https://youtu.be/video"
  )
}

@Test func cleanLinkUnwrapsGoogleRedirectAndLeavesCleanURLUnchanged() {
  #expect(
    CleanLink.clean(
      URL(
        string:
          "https://www.google.com/url?q=https%3A%2F%2Fexample.com%2Fsearch%3Fq%3Dcats%26utm_source%3Dgoogle&sa=U"
      )!
    ).absoluteString
      == "https://example.com/search?q=cats"
  )
  let plain = URL(string: "https://example.com/search?q=cats&page=2")!
  #expect(CleanLink.clean(plain) == plain)
}

@Test func cleanLinkRemovesSpotifyShareParameter() {
  #expect(
    CleanLink.clean(URL(string: "https://open.spotify.com/track/id?si=share&foo=bar")!)
      .absoluteString
      == "https://open.spotify.com/track/id?foo=bar"
  )
}

@Test func cleanLinkCleansRegionalAmazonQueryAndReferralPath() {
  let input = URL(
    string:
      "https://www.amazon.co.uk/Desk-Lamp/dp/B0/ref=sr_1_1?keywords=lamp&ref_=nav&pf_rd_p=x&qid=1")!
  #expect(
    CleanLink.clean(input).absoluteString
      == "https://www.amazon.co.uk/Desk-Lamp/dp/B0?keywords=lamp&qid=1")
}

@Test func cleanLinkMatchesTrackingKeysCaseInsensitivelyAndKeepsFragments() {
  #expect(
    CleanLink.clean(URL(string: "https://example.com/a?UTM_Source=x&FBCLID=y&id=7")!)
      .absoluteString == "https://example.com/a?id=7")
  #expect(
    CleanLink.clean(URL(string: "https://example.com/page?utm_medium=mail#section")!)
      .absoluteString == "https://example.com/page#section")
}

@Test func cleanLinkRemovesEveryAdvertisingClickIdentifier() {
  let input = URL(
    string:
      "https://shop.example/item?gclid=1&msclkid=2&mc_cid=3&mc_eid=4&dclid=5&gbraid=6&wbraid=7&color=red"
  )!
  #expect(CleanLink.clean(input).absoluteString == "https://shop.example/item?color=red")
}

@Test func cleanLinkKeepsSiteSpecificKeysOnOtherSites() {
  for address in [
    "https://example.com/search?s=shoes&t=2",
    "https://box.com/file?s=1",
    "https://example.com/watch?si=1",
    "https://example.com/item?tag=blue&ref=home",
  ] {
    let url = URL(string: address)!
    #expect(CleanLink.clean(url) == url)
  }
  #expect(
    CleanLink.clean(URL(string: "https://mobile.twitter.com/user/status/1?s=20")!)
      .absoluteString == "https://mobile.twitter.com/user/status/1")
}

@Test func cleanLinkUnwrapsOnlyGoogleRedirectsToWebPages() {
  #expect(
    CleanLink.clean(URL(string: "https://www.google.com/url?q=javascript:alert(1)&utm_source=x")!)
      .absoluteString == "https://www.google.com/url?q=javascript:alert(1)")
  let search = URL(string: "https://www.google.com/search?q=https://example.com")!
  #expect(CleanLink.clean(search) == search)
  #expect(
    CleanLink.clean(
      URL(string: "https://google.com/url?q=https%3A%2F%2Fexample.com%2F%3Fgclid%3D1")!
    )
    .absoluteString == "https://example.com/")
}
