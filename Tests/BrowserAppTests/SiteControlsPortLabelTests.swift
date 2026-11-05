// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Test func siteControlHeaderIdentifiesThePortOfItsOrigin() throws {
  let tabID = UUID()
  let profileID = UUID()
  let standard = SiteControlTarget(
    tabID: tabID, profileID: profileID,
    url: try #require(URL(string: "https://example.test/path")))
  let custom = SiteControlTarget(
    tabID: tabID, profileID: profileID,
    url: try #require(URL(string: "https://example.test:8443/path")))
  let ipv6 = SiteControlTarget(
    tabID: tabID, profileID: profileID,
    url: try #require(URL(string: "https://[::1]:8443/path")))

  #expect(standard.host == "example.test")
  #expect(custom.host == "example.test:8443")
  #expect(ipv6.host == "[::1]:8443")
}
