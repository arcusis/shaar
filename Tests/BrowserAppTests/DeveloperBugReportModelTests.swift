// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeveloperBugReportModelTests {
  @Test func closedModelDoesNotStartBugReport() async throws {
    let model = DeveloperPageModel(
      target: SiteControlTarget(
        tabID: UUID(), profileID: UUID(),
        url: try #require(URL(string: "https://example.test"))),
      engine: nil)
    model.close()

    #expect(await model.createBugReport() == nil)
    #expect(!model.creatingBugReport)
    #expect(model.reportFailure == nil)
  }

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
      request failed Authorization: Bearer fixture-bearer {"access_token":"fixture-json-token"} https://report-user:fixture-url-password@report.localhost/callback?custom=fixture-url-query#fixture-fragment&code=fixture-code&STATE=fixture-state eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signatureValue123
      Cookie: session=fixture-cookie
      Password: fixture password with spaces
      """

    let value = DeveloperPageModel.redactedConsoleMessage(raw)

    #expect(value.contains("request failed"))
    for secret in [
      "fixture-bearer", "fixture-json-token", "fixture-query", "fixture-code", "fixture-state",
      "fixture-cookie", "fixture password with spaces", "fixture-url-password",
      "fixture-url-query", "fixture-fragment",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signatureValue123",
    ] {
      #expect(!value.contains(secret), "\(secret)")
    }
    #expect(value.contains("https://report.localhost/callback"))
  }
}
