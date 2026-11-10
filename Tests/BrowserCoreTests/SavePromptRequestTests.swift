// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

private let profile = UUID()
private let tab = UUID()

private func payload(
  prompt: String = "password",
  origin: String = "http://127.0.0.1:9",
  page: String = "http://127.0.0.1:9/saved",
  detail: String = "parity-user",
  update: Bool = false,
  extra: [String: Any] = [:]
) -> [String: Any] {
  var value: [String: Any] = [
    "schemaVersion": 1,
    "kind": "savePromptRequested",
    "id": "prompt-1",
    "prompt": prompt,
    "origin": origin,
    "pageURL": page,
    "detail": detail,
    "update": update,
    "profileID": profile.uuidString,
    "tabID": tab.uuidString,
    "windowID": "window-1",
  ]
  for (key, item) in extra { value[key] = item }
  return value
}

@Test func savePromptAcceptsPasswordCardAndAddressOffers() {
  let password = SavePromptRequest(payload: payload())
  let card = SavePromptRequest(
    payload: payload(prompt: "card", detail: "Visa •••• 1111"))
  let address = SavePromptRequest(
    payload: payload(prompt: "address", detail: "Parity Probe, 1 Loopback Road, Local"))
  #expect(password?.kind == .password)
  #expect(password?.allowsNever == true)
  #expect(card?.kind == .card)
  #expect(card?.allowsNever == false)
  #expect(address?.kind == .address)
  #expect(password?.update == false)
}

@Test func savePromptRejectsSecretsAndUnknownFields() {
  #expect(SavePromptRequest(payload: payload(extra: ["password": "parity-secret"])) == nil)
  #expect(SavePromptRequest(payload: payload(extra: ["pan": "4111111111111111"])) == nil)
  #expect(SavePromptRequest(payload: payload(extra: ["number": "4111111111111111"])) == nil)
  #expect(SavePromptRequest(payload: payload(detail: "line\nbreak")) == nil)
  #expect(SavePromptRequest(payload: payload(detail: String(repeating: "a", count: 121))) == nil)
  #expect(SavePromptRequest(payload: payload(prompt: "card", update: true)) == nil)
  #expect(SavePromptRequest(payload: payload(origin: "http://user:secret@127.0.0.1:9")) == nil)
  #expect(SavePromptRequest(payload: payload(page: "http://127.0.0.1:9/saved?x=1")) == nil)
  #expect(SavePromptRequest(payload: payload(origin: "http://example.com")) != nil)
  var missing = payload()
  missing.removeValue(forKey: "detail")
  #expect(SavePromptRequest(payload: missing) == nil)
}

@Test func savePromptNeverAppliesOnlyToANewPassword() {
  let password = SavePromptRequest(payload: payload())
  let update = SavePromptRequest(payload: payload(update: true))
  let card = SavePromptRequest(payload: payload(prompt: "card", detail: "Visa •••• 1111"))
  #expect(password?.decision(.never, matchesSession: true) == .never)
  #expect(password?.decision(.save, matchesSession: false) == .dismiss)
  #expect(update?.decision(.never, matchesSession: true) == .dismiss)
  #expect(update?.allowsNever == false)
  #expect(card?.decision(.never, matchesSession: true) == .dismiss)
}
