// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeMediaTransport: ShaarMediaTransport {
  var reply: Data
  private(set) var calls: [(ShaarMediaScope, ShaarMediaOperation, Data)] = []

  init(_ reply: String) { self.reply = Data(reply.utf8) }

  func submit(
    scope: ShaarMediaScope, operation: ShaarMediaOperation, arguments: Data
  ) async throws -> Data {
    calls.append((scope, operation, arguments))
    return reply
  }

  func setReply(_ value: String) { reply = Data(value.utf8) }
}

@Test func stateDecodesNativeFieldsAndUsesExactScope() async throws {
  let fake = FakeMediaTransport(
    #"{"schemaVersion":1,"playbackState":"playing","title":"Song","artist":"Artist","album":"Record","artwork":null,"supportedActions":[0,1,3],"canSeek":true,"hasVideo":true,"tabMuted":false,"pageVolume":0.5,"silent":false,"pipVideoState":null,"videoWidth":1920,"videoHeight":1080}"#
  )
  let scope = ShaarMediaScope(profileID: "regular", sessionID: "private-1", tabID: "tab-7")
  let state = try await ShaarMediaAdapter(implementation: .shaar, transport: fake).state(
    scope: scope)
  #expect(state.playbackState == .playing)
  #expect(state.supportedActions == [0, 1, 3])
  #expect(state.videoWidth == 1920)
  let calls = await fake.calls
  #expect(calls[0].0 == scope)
  #expect(calls[0].1 == .getState)
}

@Test func malformedStateAndInvalidControlsAreRejected() async throws {
  let malformed = FakeMediaTransport(
    #"{"schemaVersion":2,"playbackState":"playing","title":"","artist":"","album":"","supportedActions":[],"canSeek":false,"hasVideo":false,"tabMuted":false}"#
  )
  await #expect(throws: (any Error).self) {
    _ = try await ShaarMediaAdapter(implementation: .shaar, transport: malformed)
      .state(scope: .init(profileID: "p", tabID: "t"))
  }

  let fake = FakeMediaTransport(#"{"schemaVersion":1}"#)
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  await #expect(throws: ShaarMediaAdapterError.invalidControl) {
    try await adapter.control(.setElementVolume, scope: .init(profileID: "p", tabID: "t"), value: 2)
  }
  #expect(await fake.calls.isEmpty)
}

@Test func controlsAndCaptureReplyCarryVersionedPayloads() async throws {
  let fake = FakeMediaTransport(#"{"schemaVersion":1}"#)
  let scope = ShaarMediaScope(profileID: "profile", tabID: "tab")
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  try await adapter.control(.seekTo, scope: scope, value: 37.5)
  try await adapter.control(.seekBackward, scope: scope, value: 12)
  try await adapter.setTabMuted(true, scope: scope)
  await fake.setReply(#"{"schemaVersion":1,"sources":[{"label":"Display 1","token":"opaque-1"}]}"#)
  let sources = try await adapter.captureSources(scope: scope)
  #expect(sources == [.init(label: "Display 1", token: "opaque-1")])
  await fake.setReply(#"{"schemaVersion":1}"#)
  try await adapter.replyToCapture(scope: scope, promptID: "prompt-1", token: "opaque-1")
  await fake.setReply(#"{"schemaVersion":1}"#)
  try await adapter.replyToCapture(scope: scope, promptID: "prompt-1", token: nil)
  let calls = await fake.calls
  #expect(
    calls.map(\.1)
      == [.control, .control, .control, .listCaptureSources, .captureReply, .captureReply])
  let seek = try #require(JSONSerialization.jsonObject(with: calls[0].2) as? [String: Any])
  #expect(seek["schemaVersion"] as? Int == 1)
  #expect(seek["command"] as? Int == ShaarMediaCommand.seekTo.rawValue)
  #expect(seek["value"] as? Double == 37.5)
  let relativeSeek = try #require(JSONSerialization.jsonObject(with: calls[1].2) as? [String: Any])
  #expect(relativeSeek["command"] as? Int == ShaarMediaCommand.seekBackward.rawValue)
  #expect(relativeSeek["value"] as? Double == 12)
  let mute = try #require(JSONSerialization.jsonObject(with: calls[2].2) as? [String: Any])
  #expect(mute["value"] as? Bool == true)
  let approved = try #require(JSONSerialization.jsonObject(with: calls[4].2) as? [String: Any])
  #expect(approved["decision"] as? String == "approve")
  #expect(approved["sourceToken"] as? String == "opaque-1")
  let cancelled = try #require(JSONSerialization.jsonObject(with: calls[5].2) as? [String: Any])
  #expect(cancelled["decision"] as? String == "cancel")
  #expect(cancelled["sourceToken"] == nil)
}

@Test func eventsCannotCrossProfilePrivateSessionOrTab() throws {
  let fake = FakeMediaTransport(#"{"schemaVersion":1}"#)
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  let event = ShaarCopiedEvent(
    sequence: 1, kind: 15, profileID: Data("p".utf8), sessionID: Data("s".utf8),
    windowID: Data(), tabID: Data("t".utf8),
    payloadJSON: Data(#"{"schemaVersion":1,"kind":"pip_changed","state":"playing"}"#.utf8))
  #expect(
    try adapter.decodeEvent(event, scope: .init(profileID: "p", sessionID: nil, tabID: "t")) == nil)
  #expect(
    try adapter.decodeEvent(event, scope: .init(profileID: "p", sessionID: "s", tabID: "other"))
      == nil)
  #expect(
    try adapter.decodeEvent(event, scope: .init(profileID: "p", sessionID: "s", tabID: "t"))
      == .pictureInPictureChanged("playing"))
}

@Test func captureEventsDecodeTypedPromptAndDismissalWithScope() throws {
  let adapter = ShaarMediaAdapter(
    implementation: .shaar, transport: FakeMediaTransport(#"{"schemaVersion":1}"#))
  let scope = ShaarMediaScope(profileID: "p", sessionID: "private-3", tabID: "t")
  let expiry = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
  let promptEvent = ShaarCopiedEvent(
    sequence: 2, kind: 15, profileID: Data("p".utf8), sessionID: Data("private-3".utf8),
    windowID: Data("w".utf8), tabID: Data("t".utf8),
    payloadJSON: Data(
      #"{"schemaVersion":1,"kind":"capture_request","promptID":"prompt-9","origin":"https://example.test","pageURL":"https://example.test/watch","frameID":"frame-2","documentID":"doc-4","expiresAtUnixMilliseconds":\#(expiry)}"#
        .utf8))
  let change = try adapter.decodeEvent(promptEvent, scope: scope)
  guard case .captureRequested(let prompt) = change else {
    Issue.record("Expected a typed capture prompt")
    return
  }
  #expect(prompt.promptID == "prompt-9")
  #expect(prompt.expiresAtUnixMilliseconds == expiry)
  #expect(try adapter.decodeEvent(promptEvent, scope: .init(profileID: "p", tabID: "t")) == nil)

  let dismissedEvent = ShaarCopiedEvent(
    sequence: 3, kind: 15, profileID: Data("p".utf8), sessionID: Data("private-3".utf8),
    windowID: Data("w".utf8), tabID: Data("t".utf8),
    payloadJSON: Data(
      #"{"schemaVersion":1,"kind":"capture_dismissed","promptID":"prompt-9","reason":"navigation"}"#
        .utf8))
  #expect(
    try adapter.decodeEvent(dismissedEvent, scope: scope)
      == .captureDismissed(promptID: "prompt-9", reason: "navigation"))
}

@Test func unversionedMutationRepliesAreRejected() async throws {
  let fake = FakeMediaTransport("{}")
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  await #expect(throws: ShaarMediaAdapterError.malformedResponse) {
    try await adapter.control(.play, scope: .init(profileID: "p", tabID: "t"))
  }
}

@Test func ardiaRemainsTheDefaultImplementationChoice() {
  let fake = FakeMediaTransport("{}")
  #expect(ShaarMediaAdapter.selected(transport: fake) == nil)
  #expect(ShaarMediaAdapter.selected(implementation: .ardia, transport: fake) == nil)
  #expect(ShaarMediaAdapter.selected(implementation: .shaar, transport: fake) != nil)
}

@Test func policyAndPictureInPictureCallsUseVersionedScopedOperations() async throws {
  let fake = FakeMediaTransport(#"{"schemaVersion":1}"#)
  let scope = ShaarMediaScope(profileID: "profile", tabID: "tab")
  let adapter = try #require(
    ShaarMediaAdapter.selected(implementation: .shaar, transport: fake))
  try await adapter.setAutoPictureInPicture(false, scope: scope)
  try await adapter.enterPictureInPicture(scope: scope)
  try await adapter.exitPictureInPicture(scope: scope)
  await #expect(throws: ShaarMediaAdapterError.invalidControl) {
    try await adapter.control(.pipSkip, scope: scope, value: 0)
  }
  let calls = await fake.calls
  #expect(
    calls.map(\.1) == [.setAutoPictureInPicture, .enterPictureInPicture, .exitPictureInPicture])
  #expect(calls.allSatisfy { $0.0 == scope })
  let policy = try #require(JSONSerialization.jsonObject(with: calls[0].2) as? [String: Any])
  #expect(policy["allowed"] as? Bool == false)
}
