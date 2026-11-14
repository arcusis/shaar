// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@Test func domCounterReplyRejectsBooleanCounts() {
  for key in ["documents", "nodes", "jsEventListeners"] {
    let withBoolean =
      "{\"schemaVersion\":1,\"commandID\":14,\"items\":[],\"\(key)\":true,\"truncated\":false}"
    #expect(
      ShaarDevToolsPhase2Reply.decode(
        Data(withBoolean.utf8), command: .domCounters) == nil)
  }
}

@Test func phase2ReplyEnvelopeRejectsBooleanAndFractionalIntegers() {
  let valid = #"{"schemaVersion":1,"commandID":14,"items":[],"truncated":false}"#
  for (field, value) in [("schemaVersion", "1"), ("commandID", "14")] {
    for replacement in ["true", "\(value).5"] {
      let payload = valid.replacingOccurrences(
        of: "\"\(field)\":\(value)", with: "\"\(field)\":\(replacement)")
      #expect(
        ShaarDevToolsPhase2Reply.decode(
          Data(payload.utf8), command: .domCounters) == nil)
    }
  }
}

@Test func phase2ReplyFlagsRequireJSONBooleans() {
  for field in ["truncated", "hasMore"] {
    let payload = #"{"schemaVersion":1,"commandID":14,"items":[],"truncated":false,"hasMore":false}"#
      .replacingOccurrences(of: "\"\(field)\":false", with: "\"\(field)\":1")
    #expect(
      ShaarDevToolsPhase2Reply.decode(
        Data(payload.utf8), command: .domCounters) == nil)
  }

  let resource = #"{"schemaVersion":1,"commandID":16,"items":[],"body":"x","base64Encoded":1,"truncated":false}"#
  #expect(
    ShaarDevToolsPhase2Reply.decode(
      Data(resource.utf8), command: .resourceContent(url: "https://example.test/a.js")) == nil)
}

@Test func phase2EventTruncatedRequiresJSONBoolean() {
  let event = ShaarCopiedEvent(
    sequence: 1, kind: 14, profileID: Data("profile".utf8), sessionID: Data(),
    windowID: Data("window".utf8), tabID: Data("tab".utf8),
    payloadJSON: Data(
      #"{"schemaVersion":1,"kind":"panelEvent","eventID":15,"leaseID":42,"data":{"isLocalStorage":true,"truncated":1}}"#.utf8))
  #expect(
    ShaarDevToolsPhase2EventRouter.decode(
      event, scope: ShaarNavigationScope(profileID: "profile"),
      windowID: "window", tabID: "tab", leaseID: 42) == nil)
}

@Test func phase2EventEnvelopeRejectsBooleanVersionAndLease() {
  let valid =
    #"{"schemaVersion":1,"kind":"panelEvent","eventID":13,"leaseID":1,"data":{"isLocalStorage":true,"key":"k","value":"v","truncated":false}}"#
  for payload in [
    valid.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":true"#),
    valid.replacingOccurrences(of: #""leaseID":1"#, with: #""leaseID":true"#),
  ] {
    let event = ShaarCopiedEvent(
      sequence: 1, kind: 14, profileID: Data("profile".utf8), sessionID: Data(),
      windowID: Data("window".utf8), tabID: Data("tab".utf8), payloadJSON: Data(payload.utf8))
    #expect(
      ShaarDevToolsPhase2EventRouter.decode(
        event, scope: .init(profileID: "profile"), windowID: "window", tabID: "tab", leaseID: 1)
        == nil)
  }
}
