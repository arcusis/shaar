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
