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

  @Test func renderPreviewDoesNotTreatFollowingSwitchAsOutputPath() {
    #expect(BrowserLaunch.previewOutputPath(in: ["app", "--render-preview", "--compact"]) == nil)
  }

  @Test func renderPreviewReturnsOutputPathWhenPresent() {
    #expect(
      BrowserLaunch.previewOutputPath(in: ["app", "--render-preview", "/tmp/preview.png"])
        == "/tmp/preview.png")
  }
}
