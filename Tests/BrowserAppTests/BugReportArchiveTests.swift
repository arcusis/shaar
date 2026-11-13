// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct BugReportArchiveTests {
  @Test func harRedactsURLCredentialsQueryValuesAndFragments() throws {
    let secretURL =
      "https://report-user:fixture-password@report.localhost/data?token=fixture-token&mode=private#fixture-fragment"
    let report = BugReportArchive.har(
      snapshot: [
        "resources": [["url": secretURL, "start": 0.0, "duration": 1.0]],
        "network": [
          [
            "url": secretURL, "start": 0.0, "end": 1.0,
            "error":
              "Failed https://error-user:error-password@report.localhost/data?token=error-token#error-fragment",
          ]
        ],
      ],
      includeSensitiveHeaders: false, version: "test")
    let encoded = try JSONSerialization.data(withJSONObject: report)
    let serialized = String(decoding: encoded, as: UTF8.self)

    #expect(!serialized.contains("fixture-password"))
    #expect(!serialized.contains("fixture-token"))
    #expect(!serialized.contains("fixture-fragment"))
    #expect(!serialized.contains("error-password"))
    #expect(!serialized.contains("error-token"))
    #expect(!serialized.contains("error-fragment"))
    let log = try #require(report["log"] as? [String: Any])
    let entries = try #require(log["entries"] as? [[String: Any]])
    let request = try #require(entries.first?["request"] as? [String: Any])
    let query = try #require(request["queryString"] as? [[String: String]])
    #expect(
      query == [
        ["name": "token", "value": "[redacted]"], ["name": "mode", "value": "[redacted]"],
      ])
  }
}
