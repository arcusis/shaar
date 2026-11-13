// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func webShareRequestAcceptsSecureOriginsAndBuildsItems() throws {
  let request = try #require(
    WebShareRequest(
      payload: sharePayload(
        origin: "https://example.com", title: "Hello", text: "World",
        url: "https://example.com/article")))

  #expect(request.originLabel == "https://example.com")
  #expect(request.url?.absoluteString == "https://example.com/article")
  #expect(request.sharingItems.count == 3)
  #expect(request.sheetID == "web-share-\(request.id)")
}

@Test func webShareRequestResolvesRelativeURLAgainstTheRequestingPage() throws {
  let request = try #require(WebShareRequest(payload: sharePayload(
    url: "../shared?source=web-share")))

  #expect(request.url == URL(string: "https://example.com/shared?source=web-share"))
}

@Test func webShareConsentOriginIncludesItsLocalhostPort() throws {
  let request = try #require(
    WebShareRequest(payload: sharePayload(origin: "http://localhost:3000")))
  #expect(request.originLabel == "http://localhost:3000")
}

@Test func webShareRequestAllowsOnlyLocalHTTPOrigins() {
  for origin in ["http://localhost", "http://127.0.0.1", "http://[::1]"] {
    #expect(WebShareRequest(payload: sharePayload(origin: origin)) != nil)
  }
  for origin in ["http://example.com", "file:///tmp/page", "https://user@example.com/path"] {
    #expect(WebShareRequest(payload: sharePayload(origin: origin)) == nil)
  }
  for origin in ["https://example.com:65536", "http://localhost:65536"] {
    #expect(WebShareRequest(payload: sharePayload(origin: origin)) == nil)
  }
}

@Test func webShareRequestRequiresRealBooleanActivationAndContent() {
  var payload = sharePayload()
  payload["userActivated"] = 1
  #expect(WebShareRequest(payload: payload) == nil)

  payload = sharePayload()
  payload["title"] = ""
  payload["text"] = ""
  #expect(WebShareRequest(payload: payload) == nil)
}

@Test func webShareRequestRejectsOversizedTextAndNonWebLinks() {
  var payload = sharePayload()
  payload["title"] = String(repeating: "x", count: 2049)
  #expect(WebShareRequest(payload: payload) == nil)

  payload = sharePayload()
  payload["url"] = "file:///tmp/private"
  #expect(WebShareRequest(payload: payload) == nil)

  payload = sharePayload(url: "https://alice:secret@example.com/private")
  #expect(WebShareRequest(payload: payload) == nil)
}

@Test func webShareRequestBoundsTitleTextAndURLByUTF8Bytes() {
  var payload = sharePayload(title: String(repeating: "é", count: 1024))
  #expect(WebShareRequest(payload: payload) != nil)

  payload["title"] = String(repeating: "é", count: 1025)
  #expect(WebShareRequest(payload: payload) == nil)

  payload = sharePayload(text: String(repeating: "💾", count: 1024))
  #expect(WebShareRequest(payload: payload) != nil)

  payload["text"] = String(repeating: "💾", count: 1025)
  #expect(WebShareRequest(payload: payload) == nil)

  payload = sharePayload(url: "https://example.com/" + String(repeating: "x", count: 4076))
  #expect(WebShareRequest(payload: payload) != nil)

  payload["url"] = "https://example.com/" + String(repeating: "é", count: 2040)
  #expect(WebShareRequest(payload: payload) == nil)
}

private func sharePayload(
  origin: String = "https://example.com", title: String = "Shared page",
  text: String = "A useful link", url: String? = nil
) -> [String: Any] {
  [
    "id": UUID().uuidString,
    "profileID": UUID().uuidString,
    "tabID": UUID().uuidString,
    "pageURL": "https://example.com/current",
    "origin": origin,
    "frameID": "main-frame",
    "title": title,
    "text": text,
    "url": url ?? "",
    "userActivated": true,
    "files": [Any](),
  ]
}
