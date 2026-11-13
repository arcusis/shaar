// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

@Test func DOMCounterReplyRejectsBooleanCounts() {
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
