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

  let fake = FakeMediaTransport("{}")
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  await #expect(throws: ShaarMediaAdapterError.invalidControl) {
    try await adapter.control(.setElementVolume, scope: .init(profileID: "p", tabID: "t"), value: 2)
  }
  #expect(await fake.calls.isEmpty)
}

@Test func controlsAndCaptureReplyCarryVersionedPayloads() async throws {
  let fake = FakeMediaTransport("{}")
  let scope = ShaarMediaScope(profileID: "profile", tabID: "tab")
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  try await adapter.control(.seekTo, scope: scope, value: 37.5)
  try await adapter.setTabMuted(true, scope: scope)
  await fake.setReply(#"{"schemaVersion":1,"sources":[{"label":"Display 1","token":"opaque-1"}]}"#)
  let sources = try await adapter.captureSources(scope: scope)
  #expect(sources == [.init(label: "Display 1", token: "opaque-1")])
  await fake.setReply("{}")
  try await adapter.replyToCapture(scope: scope, promptID: "prompt-1", token: "opaque-1")
  let calls = await fake.calls
  #expect(calls.map(\.1) == [.control, .control, .listCaptureSources, .captureReply])
  let seek = try #require(JSONSerialization.jsonObject(with: calls[0].2) as? [String: Any])
  #expect(seek["schemaVersion"] as? Int == 1)
  #expect(seek["command"] as? Int == ShaarMediaCommand.seekTo.rawValue)
  #expect(seek["value"] as? Double == 37.5)
  let mute = try #require(JSONSerialization.jsonObject(with: calls[1].2) as? [String: Any])
  #expect(mute["value"] as? Bool == true)
}

@Test func eventsCannotCrossProfilePrivateSessionOrTab() throws {
  let fake = FakeMediaTransport("{}")
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

@Test func shaarIsTheDefaultImplementationChoice() {
  let fake = FakeMediaTransport("{}")
  #expect(ShaarMediaAdapter.selected(transport: fake) != nil)
  #expect(ShaarMediaAdapter.selected(implementation: .shaar, transport: fake) != nil)
  #expect(ShaarMediaAdapter.selected(implementation: .shaar, transport: fake) != nil)
}
