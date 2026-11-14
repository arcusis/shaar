// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct PrintRequestTitleSanitizationTests {
  private func title(_ value: String) throws -> String {
    let request = try #require(
      PrintRequest(payload: [
        "schemaVersion": 1,
        "id": UUID().uuidString,
        "profileID": UUID().uuidString,
        "tabID": UUID().uuidString,
        "pageURL": "https://example.com/article",
        "origin": "https://example.com",
        "frameID": "0123456789abcdef0123456789abcdef",
        "title": value,
      ]))
    return request.title
  }

  @Test func removesInvisibleFormattingThatCanSpoofConsentTitles() throws {
    #expect(try title("Print\u{200B}Page") == "Print Page")
    #expect(try title("Print\u{2060}Page") == "Print Page")
    #expect(try title("Print\u{FEFF}Page") == "Print Page")
  }

  @Test func preservesJoinersAndEmojiTagSequences() throws {
    let family = "👩‍👩‍👧‍👦"
    let persian = "می\u{200C}روم"
    let blackFlagEngland = "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"

    #expect(try title(family) == family)
    #expect(try title(persian) == persian)
    #expect(try title(blackFlagEngland) == blackFlagEngland)
  }
}
