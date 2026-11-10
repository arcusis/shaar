// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridgeVerification
import Foundation
import Testing

private func offer(
  id: String = "prompt-1", detail: String = "parity-user", extra: [String: Any] = [:]
) -> [String: Any] {
  var payload: [String: Any] = [
    "schemaVersion": 1,
    "kind": "savePromptRequested",
    "id": id,
    "prompt": "password",
    "origin": "http://127.0.0.1:9",
    "pageURL": "http://127.0.0.1:9/saved",
    "detail": detail,
    "update": false,
  ]
  for (key, value) in extra { payload[key] = value }
  return payload
}

@Test func savePromptBridgeAcceptsOneOfferForTheOwnedTab() {
  let result = ARCProbeShaarSavePromptDispatch([offer()], "OWNED-TAB", true)
  #expect(result["requestCount"] as? Int == 1)
  #expect(result["id"] as? String == "prompt-1")
}

@Test func savePromptBridgeDropsRejectedKeysDuplicatesAndOtherTabs() {
  let secret = ARCProbeShaarSavePromptDispatch(
    [offer(extra: ["password": "parity-secret"])], "OWNED-TAB", true)
  #expect(secret["requestCount"] as? Int == 0)

  let bidi = ARCProbeShaarSavePromptDispatch(
    [offer(detail: "user\u{202E}admin")], "OWNED-TAB", true)
  #expect(bidi["requestCount"] as? Int == 0)

  let duplicate = ARCProbeShaarSavePromptDispatch(
    [offer(), offer(id: "prompt-1")], "OWNED-TAB", true)
  #expect(duplicate["requestCount"] as? Int == 1)

  let otherTab = ARCProbeShaarSavePromptDispatch([offer()], "OTHER-TAB", true)
  #expect(otherTab["requestCount"] as? Int == 0)

  let oldEngine = ARCProbeShaarSavePromptDispatch([offer()], "OWNED-TAB", false)
  #expect(oldEngine["requestCount"] as? Int == 0)
}
