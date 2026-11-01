// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import XCTest

final class SiteSettingKeyTests: XCTestCase {
  func testWebPagesUseTheirLowercasedHost() {
    XCTAssertEqual(
      SiteSettingKey.site(for: URL(string: "https://WWW.YouTube.com/watch?v=1")!),
      "www.youtube.com")
    XCTAssertEqual(
      SiteSettingKey.site(for: URL(string: "http://music.example.:8080/")!), "music.example")
  }

  func testOtherSchemesHaveNoSite() {
    XCTAssertNil(SiteSettingKey.site(for: URL(string: "file:///Users/test/video.mp4")!))
    XCTAssertNil(SiteSettingKey.site(for: URL(string: "about:blank")!))
    XCTAssertNil(SiteSettingKey.site(for: URL(string: "chrome://settings")!))
  }
}
