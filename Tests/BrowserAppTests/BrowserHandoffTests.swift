// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func browsingActivityAdvertisesOnlySafeWebPages() throws {
  let url = try #require(URL(string: "https://handoff.example/article"))
  let activity = NSUserActivity(activityType: BrowserHandoff.activityType)

  #expect(BrowserHandoff.update(activity, for: url, title: "  Article title  "))
  #expect(activity.webpageURL == url)
  #expect(activity.title == "Article title")
  #expect(activity.isEligibleForHandoff)
  #expect(!activity.isEligibleForSearch)
  #expect(!activity.isEligibleForPublicIndexing)
  #expect(BrowserHandoff.continuationURL(for: activity) == url)
  var continuedURL: URL?
  BrowserHandoff.continueBrowsing(activity) { continuedURL = $0 }
  #expect(continuedURL == url)

  let credentialURL = try #require(URL(string: "https://name:secret@handoff.example/"))
  #expect(!BrowserHandoff.update(activity, for: credentialURL, title: nil))
  #expect(!activity.isEligibleForHandoff)
  #expect(BrowserHandoff.webURL(URL(string: "javascript:alert(1)")) == nil)
}

@Test func continuationRequiresTheBrowsingWebActivityType() throws {
  let activity = NSUserActivity(activityType: "com.example.unrelated")
  activity.webpageURL = URL(string: "https://handoff.example/")

  #expect(BrowserHandoff.continuationURL(for: activity) == nil)
  var continued = false
  BrowserHandoff.continueBrowsing(activity) { _ in continued = true }
  #expect(!continued)
}
