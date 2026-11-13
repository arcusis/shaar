// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite struct WebsitePermissionPromptProbeTests {
  @Test func missingProbeArgumentsFailBeforeLaunch() {
    #expect(WebsitePermissionPromptProbe.run(arguments: ["--probe-website-permission"]) == 1)
  }

  @Test func passedRequiresTheFourWebsitePrompts() {
    let ready = WebsitePermissionProbeVerdict.passed(
      error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
      unexpectedSurfaces: [], promptedNames: ["media"], rememberedKinds: [], openedProtocols: [])
    #expect(!ready)
    let complete = WebsitePermissionProbeVerdict.passed(
      error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
      unexpectedSurfaces: [],
      promptedNames: ["media", "geolocation", "notifications", "midi", "protocol"],
      rememberedKinds: ["geolocation", "notifications", "midi"],
      openedProtocols: ["web+shaarparity", "mailto"])
    #expect(complete)
  }

  @Test func passedRequiresEveryMediaAndHiddenSurfaceCheck() {
    let prompts = ["media", "geolocation", "notifications", "midi", "protocol"]
    for failingCheck in ["error", "mediaPrompted", "mediaTracks", "hidden", "surface"] {
      let result = WebsitePermissionProbeVerdict.passed(
        error: failingCheck == "error" ? "fixture failed" : nil,
        mediaPrompted: failingCheck != "mediaPrompted",
        mediaTracks: failingCheck != "mediaTracks",
        hidden: failingCheck != "hidden",
        unexpectedSurfaces: failingCheck == "surface" ? ["NSOpenPanel"] : [],
        promptedNames: prompts, rememberedKinds: ["geolocation", "notifications", "midi"],
        openedProtocols: [])
        promptedNames: prompts,
        rememberedKinds: ["geolocation", "notifications", "midi"])
      #expect(!result, "\(failingCheck) must prevent a pass")
    }
  }

  @Test func extraPromptNamesDoNotSubstituteForARequiredPrompt() {
    let result = WebsitePermissionProbeVerdict.passed(
      error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
      unexpectedSurfaces: [],
      promptedNames: ["media", "geolocation", "notifications", "midi", "protocol", "clipboard"]
        .filter { $0 != "midi" },
      rememberedKinds: ["geolocation", "notifications", "midi"],
      openedProtocols: ["web+shaarparity", "mailto"])
      rememberedKinds: ["geolocation", "notifications", "midi"])
    #expect(!result)
  }

  @Test func passedRequiresBothRegisteredProtocolRoutes() {
    #expect(!WebsitePermissionProbeVerdict.passed(
      error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
      unexpectedSurfaces: [],
      promptedNames: ["media", "geolocation", "notifications", "midi", "protocol"],
      rememberedKinds: ["geolocation", "notifications", "midi"],
      openedProtocols: ["web+shaarparity"]))
  }

  @Test(arguments: ["geolocation", "notifications", "midi"])
  func passedFailsWhenAnyRequestedPromptIsMissing(_ missing: String) {
    let prompted = ["media", "geolocation", "notifications", "midi", "protocol"]
      .filter { $0 != missing }
    #expect(
      !WebsitePermissionProbeVerdict.passed(
        error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
        unexpectedSurfaces: [], promptedNames: prompted,
        rememberedKinds: ["geolocation", "notifications", "midi"],
        openedProtocols: ["web+shaarparity", "mailto"]))
  }

  @Test(arguments: ["geolocation", "notifications", "midi"])
  func passedRequiresEachDecisionToBeRemembered(_ missing: String) {
    let remembered = ["geolocation", "notifications", "midi"].filter { $0 != missing }
    #expect(
      !WebsitePermissionProbeVerdict.passed(
        error: nil, mediaPrompted: true, mediaTracks: true, hidden: true,
        unexpectedSurfaces: [],
        promptedNames: ["media", "geolocation", "notifications", "midi", "protocol"],
        rememberedKinds: remembered,
        openedProtocols: ["web+shaarparity", "mailto"]))

  }
}
