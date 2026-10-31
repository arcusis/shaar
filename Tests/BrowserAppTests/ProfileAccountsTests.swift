// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct ProfileAccountsTests {
  @Test func googleAccountListReadsThePrimarySignedInAccount() {
    let body = """
      ["gaia.l.a.r",[["gaia.l.a",1,"Alex Example","alex@example.com","https://lh3.googleusercontent.com/a/photo",1,1,0,null,1,"1234"],["gaia.l.a",1,"Second","second@example.com","",1,1,0,null,1,"5678"]]]
      """
    let account = GoogleAccountList.accounts(fromBody: body)?.first
    #expect(account?.email == "alex@example.com")
    #expect(account?.name == "Alex Example")
    #expect(account?.photoURL?.host() == "lh3.googleusercontent.com")
    #expect(GoogleAccountList.accounts(fromBody: #"["gaia.l.a.r",[]]"#) == [])
    #expect(GoogleAccountList.accounts(fromBody: "") == nil)
    #expect(GoogleAccountList.readScript.contains("open('POST', location.href"))
    #expect(GoogleAccountList.accounts(fromBody: "<html>Sign in</html>") == nil)
  }

  @Test func providersRecognizeTheirSignedInLandingPages() {
    #expect(AccountProvider.google.isSignedInPage(URL(string: "https://myaccount.google.com/")!))
    #expect(AccountProvider.google.isSignedInPage(URL(string: "https://www.google.com/")!))
    #expect(AccountProvider.google.isSignedInPage(URL(string: "https://mail.google.com/mail/")!))
    #expect(
      !AccountProvider.google.isSignedInPage(URL(string: "https://accounts.google.com/v3/signin")!))
    #expect(!AccountProvider.google.isSignedInPage(URL(string: "https://google.com.evil.test/")!))
    #expect(
      AccountProvider.microsoft.isSignedInPage(URL(string: "https://www.microsoft365.com/?auth=2")!)
    )
    #expect(
      !AccountProvider.microsoft.isSignedInPage(URL(string: "https://www.microsoft365.com/login")!))
    #expect(
      MicrosoftSignInPage.isSignInPage(URL(string: "https://login.microsoftonline.com/common")!))
    #expect(AccountProvider.allCases.allSatisfy { $0.logo != nil })
  }

  @Test func microsoftWorkAccountRedirectsCaptureEmailFromExternalIdentityProvider() {
    let microsoft = URL(
      string: "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize")!
    let okta = URL(string: "https://acme.okta.com/login/login.htm?login_hint=worker%40acme.test")!
    let adfs = URL(string: "https://sso.acme.test/adfs/ls/?username=worker%40acme.test")!
    let ping = URL(string: "https://id.acme.test/as/authorization.oauth2?email=worker%40acme.test")!

    #expect(MicrosoftSignInPage.isSignInPage(microsoft))
    #expect(MicrosoftSignInPage.isIdentityProviderPage(okta))
    #expect(MicrosoftSignInPage.isIdentityProviderPage(adfs))
    #expect(MicrosoftSignInPage.isIdentityProviderPage(ping))
    #expect(MicrosoftSignInPage.email(in: okta) == "worker@acme.test")
    #expect(MicrosoftSignInPage.email(in: adfs) == "worker@acme.test")
    #expect(MicrosoftSignInPage.email(in: ping) == "worker@acme.test")
    #expect(
      MicrosoftSignInPage.email(in: okta, pageText: "worker@acme.test") == "worker@acme.test")
    #expect(MicrosoftSignInPage.email(in: okta, pageText: "Continue") == "worker@acme.test")
  }

  @Test func microsoftSignInReadsEmailOnItsOwnPagesAndOnCompanyIdentityProviders() {
    let pages = [
      "https://login.live.com/oauth20_authorize.srf",
      "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      "https://acme.okta.com/app/office365/sso/wsfed/passive",
      "https://sts.acme.test/adfs/ls/",
      "https://sso.connect.pingidentity.com/sso/as/authorization.oauth2",
    ]
    for page in pages {
      #expect(MicrosoftSignInPage.mayShowAccountEmail(URL(string: page)!), "\(page)")
    }
    let notIdentityProviders = [
      "https://m365.cloud.microsoft/login", "https://www.microsoft365.com/login",
      "https://account.live.com/", "https://www.office.com/", "http://sso.acme.test/adfs/ls/",
    ]
    for page in notIdentityProviders {
      #expect(!MicrosoftSignInPage.isIdentityProviderPage(URL(string: page)!), "\(page)")
    }
    let signIn = URL(string: "https://login.microsoftonline.com/common/login")!
    #expect(
      MicrosoftSignInPage.email(in: signIn, pageText: "  person@outlook.com\n")
        == "person@outlook.com")
    #expect(MicrosoftSignInPage.email(in: signIn, pageText: "Sign in") == nil)
    #expect(MicrosoftSignInPage.email(in: signIn, pageText: "a@b@c.test") == nil)
    #expect(MicrosoftSignInPage.emailScript.contains("#mectrl_currentAccount_secondary"))
    #expect(MicrosoftSignInPage.emailScript.contains("#userNameInput"))
  }

  @Test @MainActor func accountsPersistPerProfileWithOnePerProvider() {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let profile = UUID()
    let store = BrowserPreferencesStore(fileURL: file)
    store.setAccount(ConnectedAccount(provider: .google, email: "old@example.com"), for: profile)
    store.setAccount(ConnectedAccount(provider: .google, email: "new@example.com"), for: profile)
    store.setAccount(
      ConnectedAccount(provider: .microsoft, email: "work@example.com"), for: profile)
    store.removeAccount(.microsoft, for: profile)

    let reloaded = BrowserPreferencesStore(fileURL: file)
    #expect(reloaded.accounts(for: profile).map(\.email) == ["new@example.com"])
    #expect(reloaded.accounts(for: UUID()).isEmpty)
  }
}

extension ProfileAccountsTests {
  @Test @MainActor func profileAccountPreferencesPersistAcrossReload() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let profile = UUID()
    let account = ConnectedAccount(provider: .google, email: "member@example.test")
    let store = BrowserPreferencesStore(fileURL: file)
    store.setAccount(account, for: profile)

    let reloaded = BrowserPreferencesStore(fileURL: file)
    #expect(reloaded.accounts(for: profile) == [account])
  }
}
