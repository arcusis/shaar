// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeveloperBugReportModelTests {
  @Test func reportPageURLRemovesCredentialsQueryAndFragment() {
    let raw =
      "https://report-user:fixture-password@report.localhost/page?token=fixture-token#fixture-fragment"

    let value = DeveloperPageModel.redactedReportPageURL(raw)

    #expect(value == "https://report.localhost/page")
    #expect(!value.contains("fixture-password"))
    #expect(!value.contains("fixture-token"))
    #expect(!value.contains("fixture-fragment"))
  }

  @Test func consoleMessagesRedactCommonCredentialForms() {
    let raw = """
      request failed Authorization: Bearer fixture-bearer {"access_token":"fixture-json-token"} https://example.test/callback?token=fixture-query eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signatureValue123
      Cookie: session=fixture-cookie
      """

    let value = DeveloperPageModel.redactedConsoleMessage(raw)

    #expect(value.contains("request failed"))
    for secret in [
      "fixture-bearer", "fixture-json-token", "fixture-query", "fixture-cookie",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signatureValue123",
    ] {
      #expect(!value.contains(secret), "\(secret)")
    }
  }
}
