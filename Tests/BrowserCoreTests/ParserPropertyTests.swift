// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserCore

@Suite struct ParserPropertyTests {
  @Test(arguments: [1, 2, 3, 4])
  func committedSessionSchemasLoadWithoutChangingOriginal(version: Int) throws {
    let url = UpgradeFixtures.url("session-v\(version)")
    let original = try Data(contentsOf: url)
    let session = try #require(try SessionFile(url: url).loadPrimary())
    #expect(session.version == BrowserSession.currentVersion)
    #expect(session.profiles.map(\.id) == [UpgradeFixtures.profileID])
    #expect(session.selectedSpace.name == "Fixture space")
    #expect(session.selectedSpace.tabs.map(\.title) == ["Pinned fixture", "Selected fixture"])
    #expect(session.selectedSpace.selectedTab?.title == "Selected fixture")
    #expect(session.selectedSpace.tabs[0].isPinned)
    #expect(
      session.selectedSpace.tabs[1].url.absoluteString == "https://example.invalid/saved?q=fixture")
    #expect(try Data(contentsOf: url) == original)
    let encoded = try JSONEncoder().encode(session)
    #expect(try JSONDecoder().decode(BrowserSession.self, from: encoded) == session)
  }

  @Test(arguments: SeededGenerator.seeds)
  func sessionsRoundTripAndRejectBrokenReferences(seed: UInt64) throws {
    var random = SeededGenerator(seed: seed)
    for index in 0..<64 {
      let context = "seed=\(seed), case=\(index)"
      let profile = BrowserProfile(id: random.identifier(), name: "Profile \(random.next())")
      let tabs = (0..<(1 + random.sample(8))).map { _ in
        BrowserTab(
          id: random.identifier(), url: URL(string: "https://example.invalid/\(random.next())")!,
          title: "Tab \(random.next())", isPinned: random.sample(2) == 0)
      }
      let space = BrowserSpace(
        id: random.identifier(), profileID: profile.id, name: "Space \(random.next())",
        symbol: "house", tint: .ocean, tabs: tabs,
        selectedTabID: tabs[random.sample(tabs.count)].id)
      let session = try BrowserSession(
        profiles: [profile], spaces: [space], selectedSpaceID: space.id)
      let data = try JSONEncoder().encode(session)
      #expect(try JSONDecoder().decode(BrowserSession.self, from: data) == session, "\(context)")
      var broken = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      broken["selectedSpaceID"] = random.identifier().uuidString
      let dangling = try JSONSerialization.data(withJSONObject: broken)
      #expect(throws: SessionError.invalidState, "\(context)") {
        try JSONDecoder().decode(BrowserSession.self, from: dangling)
      }
      broken["version"] = 100 + random.sample(100)
      let future = try JSONSerialization.data(withJSONObject: broken)
      #expect(throws: SessionError.unsupportedVersion, "\(context)") {
        try JSONDecoder().decode(BrowserSession.self, from: future)
      }
    }
  }

  @Test(arguments: SeededGenerator.seeds)
  func cleanLinksPreservePageContentAndAreIdempotent(seed: UInt64) throws {
    var random = SeededGenerator(seed: seed)
    let sites = [
      ("example.invalid", "gclid"), ("www.youtube.com", "si"), ("x.com", "t"),
      ("amazon.co.uk", "tag"),
    ]
    for index in 0..<128 {
      let context = "seed=\(seed), case=\(index)"
      let (host, tracking) = sites[random.sample(sites.count)]
      var components = URLComponents()
      components.scheme = "https"
      components.host = host
      components.path = "/item/\(random.next())"
      components.fragment = "section-\(random.next())"
      let kept = (0..<(1 + random.sample(6))).map { item in
        URLQueryItem(name: "keep\(item % 2)", value: "value +/?#&= \(random.next())")
      }
      var mixed = kept
      mixed.insert(
        URLQueryItem(name: tracking, value: "tracking"), at: random.sample(mixed.count + 1))
      mixed.insert(
        URLQueryItem(name: "UTM_Source", value: "mail"), at: random.sample(mixed.count + 1))
      components.queryItems = mixed
      let cleaned = CleanLink.clean(try #require(components.url))
      let actual = try #require(URLComponents(url: cleaned, resolvingAgainstBaseURL: false))
      #expect(actual.queryItems == kept, "\(context)")
      #expect(
        actual.path == components.path && actual.fragment == components.fragment, "\(context)")
      #expect(actual.host == host && actual.scheme == "https", "\(context)")
      #expect(CleanLink.clean(cleaned) == cleaned, "\(context)")
    }
  }
}
