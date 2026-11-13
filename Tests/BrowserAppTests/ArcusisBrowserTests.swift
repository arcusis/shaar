import Testing
@testable import ArcusisBrowser

struct ArcusisBrowserTests {
  @Test func missingOptionValueDoesNotConsumeFollowingSwitch() {
    #expect(
      BrowserLaunch.value(after: "--command-query", in: ["app", "--command-query", "--compact"])
        == nil)
  }

  @Test func optionValueIsReturnedWhenPresent() {
    #expect(
      BrowserLaunch.value(after: "--command-query", in: ["app", "--command-query", "swift"])
        == "swift")
  }

  @Test func missingFinalOptionValueReturnsNil() {
    #expect(BrowserLaunch.value(after: "--command-query", in: ["app", "--command-query"]) == nil)
  }
}
