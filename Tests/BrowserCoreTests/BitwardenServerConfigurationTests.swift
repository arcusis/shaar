import Foundation
import Testing

@testable import BrowserCore

@Suite struct BitwardenServerConfigurationTests {
  @Test func cloudRegionsUseDocumentedDistinctAuthorities() throws {
    let us = try BitwardenServerConfiguration(region: .us).endpoints()
    #expect(us.apiURL.absoluteString == "https://api.bitwarden.com")
    #expect(us.identityURL.absoluteString == "https://identity.bitwarden.com")
    #expect(us.credentialAuthority.absoluteString == "https://api.bitwarden.com")

    let eu = try BitwardenServerConfiguration(region: .eu).endpoints()
    #expect(eu.apiURL.absoluteString == "https://api.bitwarden.eu")
    #expect(eu.identityURL.absoluteString == "https://identity.bitwarden.eu")
    #expect(eu.credentialAuthority.absoluteString == "https://api.bitwarden.eu")
    #expect(us.stableServiceID != eu.stableServiceID)
  }

  @Test func customBasePathDerivesApiAndIdentityAndNormalizesTrailingSlash() throws {
    let first = try BitwardenServerConfiguration(
      region: .custom, customBaseURL: "https://vault.example/bitwarden/"
    ).endpoints()
    let normalized = try BitwardenServerConfiguration(
      region: .custom, customBaseURL: "https://VAULT.example/bitwarden"
    ).endpoints()
    #expect(first.apiURL.absoluteString == "https://vault.example/bitwarden/api")
    #expect(first.identityURL.absoluteString == "https://vault.example/bitwarden/identity")
    #expect(first.credentialAuthority.absoluteString == "https://vault.example")
    #expect(first.stableServiceID == normalized.stableServiceID)

    let changedBasePath = try BitwardenServerConfiguration(
      region: .custom, customBaseURL: "https://vault.example/other"
    ).endpoints()
    #expect(changedBasePath.stableServiceID != first.stableServiceID)
  }

  @Test func customConfigurationRejectsInsecureOrAmbiguousURLs() {
    for value in [
      "", "http://vault.example", "https://user@vault.example", "https://vault.example?x=1",
      "https://vault.example/#fragment", "https://vault.example/../other",
      "https://vault.example/%2e%2e/other", "https://vault.example:0",
    ] {
      #expect(throws: BitwardenServerConfigurationError.self) {
        try BitwardenServerConfiguration(region: .custom, customBaseURL: value).endpoints()
      }
    }
    #expect(throws: BitwardenServerConfigurationError.customURLRequired) {
      try BitwardenServerConfiguration(region: .custom).endpoints()
    }
  }
}
