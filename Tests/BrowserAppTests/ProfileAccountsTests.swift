import Foundation
import Testing

@testable import ArcusisBrowser

struct ProfileAccountsTests {
  @Test func googleAccountListReadsThePrimarySignedInAccount() {
    let body = """
      ["gaia.l.a.r",[["gaia.l.a",1,"Alex Example","alex@example.com","https://lh3.googleusercontent.com/a/photo",1,1,0,null,1,"1234"],["gaia.l.a",1,"Second","second@example.com","",1,1,0,null,1,"5678"]]]
      """
    let account = GoogleAccountList.primaryAccount(fromBody: body)
    #expect(account?.email == "alex@example.com")
    #expect(account?.name == "Alex Example")
    #expect(account?.photoURL?.host() == "lh3.googleusercontent.com")
    #expect(GoogleAccountList.primaryAccount(fromBody: #"["gaia.l.a.r",[]]"#) == nil)
    #expect(GoogleAccountList.primaryAccount(fromBody: "<html>Sign in</html>") == nil)
  }

  @Test func providersRecognizeTheirSignedInLandingPages() {
    #expect(AccountProvider.google.isSignedInPage(URL(string: "https://myaccount.google.com/")!))
    #expect(
      !AccountProvider.google.isSignedInPage(URL(string: "https://accounts.google.com/v3/signin")!))
    #expect(
      AccountProvider.microsoft.isSignedInPage(URL(string: "https://www.microsoft365.com/?auth=2")!)
    )
    #expect(
      !AccountProvider.microsoft.isSignedInPage(URL(string: "https://www.microsoft365.com/login")!))
    #expect(
      MicrosoftSignInPage.isSignInPage(URL(string: "https://login.microsoftonline.com/common")!))
    #expect(AccountProvider.allCases.allSatisfy { $0.logo != nil })
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
