// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func cleanLinkRemovesAmazonTracking() {
  let input = URL(
    string: "https://www.amazon.com/dp/B012345678/ref=abc?tag=store&psc=1&pd_rd_x=2&color=blue")!
  #expect(
    CleanLink.clean(input).absoluteString == "https://www.amazon.com/dp/B012345678?color=blue")
}

@Test func cleanLinkKeepsAmazonNamedNonAmazonPageData() {
  let address = "https://amazon.example.com/product/ref=manual?tag=category"
  let url = URL(string: address)!
  #expect(CleanLink.clean(url) == url)
}

@Test func cleanLinkRemovesURLCredentialsEvenWithoutTrackingParameters() {
  let input = URL(string: "https://user:secret@example.com/private")!

  let cleaned = CleanLink.clean(input)

  #expect(cleaned.absoluteString == "https://example.com/private")
  #expect(cleaned.user == nil)
  #expect(cleaned.password == nil)
}

@Test func cleanLinkPreservesQueryEncodingWhenRemovingCredentials() {
  let input = URL(
    string:
      "https://user:secret@storage.example.com/object%2Fprivate?download=https%3A%2F%2Fexample.com%2Ffile&sig=abc"
  )!

  #expect(
    CleanLink.clean(input).absoluteString
      == "https://storage.example.com/object%2Fprivate?download=https%3A%2F%2Fexample.com%2Ffile&sig=abc")
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

@Test func cleanLinkKeepsSiteParametersOnUnrelatedVideoNamedDomains() {
  for address in [
    "https://youtube.example.com/watch?si=chapter&v=123",
    "https://spotify.example.com/track?si=source",
  ] {
    let url = URL(string: address)!
    #expect(CleanLink.clean(url) == url)
  }
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

@Test func cleanLinkUnwrapsGoogleCountryDomainRedirects() {
  for host in ["www.google.co.uk", "google.de", "www.google.com.au"] {
    let wrapper = URL(
      string: "https://\(host)/url?q=https%3A%2F%2Fexample.com%2Fstory%3Futm_source%3Dgoogle"
    )!
    #expect(CleanLink.clean(wrapper).absoluteString == "https://example.com/story")
  }
  let lookalike = URL(string: "https://google.example.com/url?q=https%3A%2F%2Fexample.com")!
  #expect(CleanLink.clean(lookalike).host() == "google.example.com")
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

@Test func cleanLinkPreservesAmazonPathSeparators() {
  for (address, expected) in [
    ("https://www.amazon.com/dp/B0/", "https://www.amazon.com/dp/B0/"),
    ("https://www.amazon.com/gp//product/B0/?tag=store", "https://www.amazon.com/gp//product/B0/"),
    ("https://www.amazon.com/gp//product/B0/ref=share/", "https://www.amazon.com/gp//product/B0/"),
  ] {
    let input = URL(string: address)!
    #expect(CleanLink.clean(input).absoluteString == expected)
  }
}

@Test func cleanLinkMatchesTrackingKeysCaseInsensitivelyAndKeepsFragments() {
  #expect(
    CleanLink.clean(URL(string: "https://example.com/a?UTM_Source=x&FBCLID=y&id=7")!)
      .absoluteString == "https://example.com/a?id=7")
  #expect(
    CleanLink.clean(URL(string: "https://example.com/page?utm_medium=mail#section")!)
      .absoluteString == "https://example.com/page#section")
}

@Test func cleanLinkPreservesQueryEncodingWhenThereIsNoTracking() {
  let input = URL(
    string:
      "https://storage.example.com/object?download=https%3A%2F%2Fexample.com%2Ffile&sig=abc"
  )!
  #expect(CleanLink.clean(input).absoluteString == input.absoluteString)
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

@Test func cleanLinkKeepsGoogleRedirectToHostlessURL() {
  let original = URL(string: "https://www.google.com/url?q=https:/missing-host")!
  #expect(CleanLink.clean(original) == original)
}
