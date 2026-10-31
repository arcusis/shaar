// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct ProfileAccountParsingTests {
  @Test func googleAccountListSkipsEntriesWithoutAnAddressAndUnsafePhotos() throws {
    let body = """
      ["gaia.l.a.r",[["gaia.l.a",1,"No Address","not-an-address","",1],["gaia.l.a",1],["gaia.l.a",1,null,"plain@example.com","http://insecure.example/photo",1],["gaia.l.a",1,"Number",42,"",1]]]
      """
    let accounts = try #require(GoogleAccountList.accounts(fromBody: body))
    #expect(accounts.map(\.email) == ["plain@example.com"])
    #expect(accounts.first?.name == nil)
    #expect(accounts.first?.photoURL == nil)
    #expect(accounts.first?.provider == .google)
  }

  @Test func googleAccountPhotosAcceptFullAndSchemeRelativeSecureAddresses() throws {
    let body = """
      ["gaia.l.a.r",[["gaia.l.a",1,"Alex","alex@example.com","//lh3.googleusercontent.com/a/alex=s48-c",1]]]
      """
    let account = try #require(GoogleAccountList.accounts(fromBody: body)?.first)
    #expect(account.photoURL?.absoluteString == "https://lh3.googleusercontent.com/a/alex=s48-c")
    #expect(
      GoogleAccountList.photoURL(from: "https://lh3.googleusercontent.com/a/photo")?.host()
        == "lh3.googleusercontent.com")
    for rejected in ["", "http://lh3.googleusercontent.com/a/photo", "photo.jpg", "https://"] {
      #expect(GoogleAccountList.photoURL(from: rejected) == nil, "\(rejected)")
    }
  }

  @Test func googleAccountListRejectsBodiesThatAreNotTheList() {
    for body in [#"{"error":"denied"}"#, #"["gaia.l.a.r"]"#, #"["gaia.l.a.r","entries"]"#, "[]"] {
      #expect(GoogleAccountList.accounts(fromBody: body) == nil)
    }
  }

  @Test func providerSignInAndSignOutPagesStayOnProviderHosts() {
    #expect(AccountProvider.google.signInURL.host() == "accounts.google.com")
    #expect(AccountProvider.google.signOutURL.host() == "accounts.google.com")
    #expect(AccountProvider.microsoft.signInURL.host() == "www.microsoft365.com")
    #expect(AccountProvider.microsoft.signOutURL.host() == "login.microsoftonline.com")
    let pages = AccountProvider.allCases.flatMap { [$0.signInURL, $0.signOutURL] }
    #expect(pages.allSatisfy { $0.scheme == "https" })
    #expect(AccountProvider.allCases.map(\.title) == ["Google", "Microsoft"])
    #expect(AccountProvider.allCases.map(\.id) == ["google", "microsoft"])
  }

  @Test func microsoftLandingPagesCountOnlyAfterSignIn() {
    for address in [
      "https://m365.cloud.microsoft/", "https://www.office.com/", "https://outlook.live.com/mail/",
      "https://outlook.office.com/mail/",
    ] {
      #expect(AccountProvider.microsoft.isSignedInPage(URL(string: address)!))
    }
    #expect(
      !AccountProvider.microsoft.isSignedInPage(URL(string: "https://login.microsoftonline.com/")!))
    #expect(
      !AccountProvider.microsoft.isSignedInPage(URL(string: "https://www.office.com.evil.test/")!))
    #expect(MicrosoftSignInPage.isSignInPage(URL(string: "https://login.live.com/login.srf")!))
    #expect(!MicrosoftSignInPage.isSignInPage(URL(string: "https://www.microsoft365.com/")!))
  }

  @Test func connectedAccountsRoundTripThroughJSON() throws {
    let account = ConnectedAccount(
      provider: .microsoft, email: "work@example.com", name: "Work",
      photoURL: URL(string: "https://example.com/photo.png"))
    let decoded = try JSONDecoder().decode(
      ConnectedAccount.self, from: JSONEncoder().encode(account))
    #expect(decoded == account)
  }
}
