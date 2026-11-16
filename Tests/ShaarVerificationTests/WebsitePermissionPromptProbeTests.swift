// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite struct WebsitePermissionPromptProbeTests {
  private let prompts = [
    "media-allow", "media-deny", "geolocation", "notifications", "midi", "protocol",
  ]

  @Test func missingProbeArgumentsFailBeforeLaunch() {
    #expect(WebsitePermissionPromptProbe.run(arguments: ["--probe-website-permission"]) == 1)
  }

  @Test func passedRequiresTheFourWebsitePromptsAndBothMediaDecisions() {
    let ready = verdict(promptedNames: ["media-allow"], rememberedKinds: [])
    #expect(!ready)
    let complete = verdict(
      promptedNames: prompts,
      rememberedKinds: ["geolocation", "notifications", "midi"],
      openedProtocols: ["web+shaarparity"])
    #expect(complete)
  }

  @Test(arguments: ["error", "mediaPrompted", "mediaTracks", "mediaDenied", "hidden", "surface"])
  func passedRequiresEveryMediaAndHiddenSurfaceCheck(_ failingCheck: String) {
    #expect(
      !verdict(
        error: failingCheck == "error" ? "fixture failed" : nil,
        mediaPrompted: failingCheck != "mediaPrompted",
        mediaTracks: failingCheck != "mediaTracks",
        mediaDenied: failingCheck != "mediaDenied",
        hidden: failingCheck != "hidden",
        unexpectedSurfaces: failingCheck == "surface" ? ["NSOpenPanel"] : [],
        promptedNames: prompts,
        rememberedKinds: ["geolocation", "notifications", "midi"]))
  }

  @Test func extraPromptNamesDoNotSubstituteForARequiredPrompt() {
    #expect(
      !verdict(
        promptedNames: prompts.filter { $0 != "midi" } + ["clipboard"],
        rememberedKinds: ["geolocation", "notifications", "midi"],
        openedProtocols: ["web+shaarparity"]))
  }

  @Test func passedRequiresShaarWebProtocolRegistration() {
    #expect(
      !verdict(
        promptedNames: prompts,
        rememberedKinds: ["geolocation", "notifications", "midi"]))
  }

  @Test(arguments: ["geolocation", "notifications", "midi"])
  func passedFailsWhenAnyRequestedPromptIsMissing(_ missing: String) {
    #expect(
      !verdict(
        promptedNames: prompts.filter { $0 != missing },
        rememberedKinds: ["geolocation", "notifications", "midi"],
        openedProtocols: ["web+shaarparity"]))
  }

  @Test(arguments: ["geolocation", "notifications", "midi"])
  func passedRequiresEachDecisionToBeRemembered(_ missing: String) {
    #expect(
      !verdict(
        promptedNames: prompts,
        rememberedKinds: ["geolocation", "notifications", "midi"].filter { $0 != missing },
        openedProtocols: ["web+shaarparity"]))
  }

  private func verdict(
    error: String? = nil, mediaPrompted: Bool = true, mediaTracks: Bool = true,
    mediaDenied: Bool = true, hidden: Bool = true, unexpectedSurfaces: [String] = [],
    promptedNames: [String], rememberedKinds: [String], openedProtocols: Set<String> = []
  ) -> Bool {
    WebsitePermissionProbeVerdict.passed(
      error: error, mediaPrompted: mediaPrompted, mediaTracks: mediaTracks,
      mediaDenied: mediaDenied, hidden: hidden, unexpectedSurfaces: unexpectedSurfaces,
      promptedNames: promptedNames, rememberedKinds: rememberedKinds,
      openedProtocols: openedProtocols)
  }
}
