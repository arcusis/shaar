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
    #"{"schemaVersion":1,"playbackState":"playing","title":"Song","artist":"Artist","album":"Record","artwork":null,"supportedActions":[0,1,3],"canSeek":true,"hasVideo":true,"tabMuted":false,"pageVolume":0.5,"silent":false,"pipVideoState":"inPictureInPicture","pipVideoIsLive":true,"videoWidth":1920,"videoHeight":1080}"#
  )
  let scope = ShaarMediaScope(profileID: "regular", sessionID: "private-1", tabID: "tab-7")
  let state = try await ShaarMediaAdapter(implementation: .shaar, transport: fake).state(
    scope: scope)
  #expect(state.playbackState == .playing)
  #expect(state.supportedActions == [0, 1, 3])
  #expect(state.videoWidth == 1920)
  #expect(state.pipVideoIsLive == true)
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

@Test func captureCancellationOmitsTheSourceToken() async throws {
  let fake = FakeMediaTransport("{}")
  let adapter = ShaarMediaAdapter(transport: fake)
  try await adapter.replyToCapture(
    scope: ShaarMediaScope(profileID: "profile", tabID: "tab"), promptID: "prompt", token: nil)
  let calls = await fake.calls
  #expect(calls.count == 1)
  #expect(calls[0].1 == .captureReply)
  let arguments = try #require(
    JSONSerialization.jsonObject(with: calls[0].2) as? [String: Any])
  #expect(arguments["schemaVersion"] as? Int == 1)
  #expect(arguments["promptID"] as? String == "prompt")
  #expect(arguments["decision"] as? String == "cancel")
  #expect(arguments["sourceToken"] == nil)
}

@Test func tenSecondSeekCommandsCarryOffsets() async throws {
  let fake = FakeMediaTransport("{}")
  let scope = ShaarMediaScope(profileID: "profile", tabID: "tab")
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  try await adapter.control(.seekBackward, scope: scope, value: 10)
  try await adapter.control(.seekForward, scope: scope, value: 10)
  let calls = await fake.calls
  #expect(calls.count == 2)
  let values = try calls.map { call in
    try #require(JSONSerialization.jsonObject(with: call.2) as? [String: Any])
  }
  #expect(values.map { $0["command"] as? Int } == [4, 5])
  #expect(values.map { $0["value"] as? Double } == [10, 10])
}

@Test func eventsCannotCrossProfilePrivateSessionOrTab() throws {
  let fake = FakeMediaTransport("{}")
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: fake)
  let event = ShaarCopiedEvent(
    sequence: 1, kind: 15, profileID: Data("p".utf8), sessionID: Data("s".utf8),
    windowID: Data(), tabID: Data("t".utf8),
    payloadJSON: Data(
      #"{"schemaVersion":1,"kind":"pip_changed","state":"inPictureInPicture"}"#.utf8))
  #expect(
    try adapter.decodeEvent(event, scope: .init(profileID: "p", sessionID: nil, tabID: "t")) == nil)
  #expect(
    try adapter.decodeEvent(event, scope: .init(profileID: "p", sessionID: "s", tabID: "other"))
      == nil)
  #expect(
    try adapter.decodeEvent(event, scope: .init(profileID: "p", sessionID: "s", tabID: "t"))
      == .pictureInPictureChanged("inPictureInPicture"))
}

@Test func invalidPictureInPictureTransitionIsRejected() throws {
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: FakeMediaTransport("{}"))
  let event = ShaarCopiedEvent(
    sequence: 1, kind: 15, profileID: Data("p".utf8), sessionID: Data(),
    windowID: Data("w".utf8), tabID: Data("t".utf8),
    payloadJSON: Data(#"{"schemaVersion":1,"kind":"pip_changed","state":"playing"}"#.utf8))
  #expect(throws: ShaarMediaAdapterError.malformedResponse) {
    try adapter.decodeEvent(event, scope: .init(profileID: "p", tabID: "t"))
  }
}

@Test func eventSchemaVersionMustBeAnInteger() throws {
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: FakeMediaTransport("{}"))
  let event = ShaarCopiedEvent(
    sequence: 1, kind: 15, profileID: Data("p".utf8), sessionID: Data(),
    windowID: Data("w".utf8), tabID: Data("t".utf8),
    payloadJSON: Data(#"{"schemaVersion":true,"kind":"pip_changed","state":"none"}"#.utf8))
  #expect(throws: ShaarMediaAdapterError.malformedResponse) {
    try adapter.decodeEvent(event, scope: .init(profileID: "p", tabID: "t"))
  }
}

@Test func stateEventsRejectInvalidNativeStateFields() throws {
  let adapter = ShaarMediaAdapter(implementation: .shaar, transport: FakeMediaTransport("{}"))
  let validFields =
    #""schemaVersion":1,"playbackState":"playing","title":"","artist":"","album":"","supportedActions":[0],"canSeek":false,"hasVideo":false,"tabMuted":false,"pageVolume":0.5"#
  let invalidFields = [
    validFields.replacingOccurrences(
      of: #""supportedActions":[0]"#, with: #""supportedActions":[99]"#),
    validFields.replacingOccurrences(of: #""pageVolume":0.5"#, with: #""pageVolume":1.5"#),
    validFields.replacingOccurrences(
      of: #""tabMuted":false"#, with: #""tabMuted":false,"videoWidth":1920"#),
  ]
  for (index, fields) in invalidFields.enumerated() {
    let payload = "{\"schemaVersion\":1,\"kind\":\"state_changed\",\"state\":{" + fields + "}}"
    let event = ShaarCopiedEvent(
      sequence: UInt64(index + 2), kind: 15, profileID: Data("p".utf8), sessionID: Data(),
      windowID: Data(), tabID: Data("t".utf8), payloadJSON: Data(payload.utf8))
    #expect(throws: ShaarMediaAdapterError.malformedResponse) {
      try adapter.decodeEvent(event, scope: .init(profileID: "p", tabID: "t"))
    }
  }
}

@Test func shaarIsTheDefaultImplementationChoice() {
  let fake = FakeMediaTransport("{}")
  #expect(ShaarMediaAdapter.selected(transport: fake) != nil)
  #expect(ShaarMediaAdapter.selected(implementation: .shaar, transport: fake) != nil)
  #expect(ShaarMediaAdapter.selected(implementation: .shaar, transport: fake) != nil)
}
