// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func websitePermissionRequestsRequireSecureOriginsAndKnownCapabilities() throws {
  let page = URL(string: "https://meet.google.com/example")!
  let profile = UUID()
  let tab = UUID()
  func request(origin: String, kinds: [WebsitePermissionKind] = [.camera, .microphone])
    -> WebsitePermissionRequest?
  {
    WebsitePermissionRequest(
      id: "p1", profileID: profile, tabID: tab, pageURL: page,
      requestingOrigin: URL(string: origin)!, kinds: kinds)
  }
  #expect(request(origin: "https://meet.google.com") != nil)
  #expect(request(origin: "http://127.0.0.1:1234") != nil)
  #expect(request(origin: "http://example.com") == nil)
  #expect(request(origin: "https://meet.google.com/path") == nil)
  #expect(request(origin: "https://user:secret@meet.google.com") == nil)
  #expect(request(origin: "https://meet.google.com?other=example.com") == nil)
  #expect(request(origin: "https://meet.google.com", kinds: []) == nil)
  #expect(request(origin: "https://meet.google.com", kinds: [.camera, .camera]) == nil)
  #expect(WebsitePermissionKind(rawValue: "screen") == nil)
  #expect(WebsitePermissionKind(rawValue: "cameraPanTiltZoom") == nil)
}

@Test func websitePermissionRequestsAcceptLocalhostSubdomains() {
  func request(_ origin: String) -> WebsitePermissionRequest? {
    WebsitePermissionRequest(
      id: "local", profileID: UUID(), tabID: UUID(),
      pageURL: URL(string: "http://app.localhost:8080/page")!,
      requestingOrigin: URL(string: origin)!, kinds: [.camera])
  }

  #expect(request("http://app.localhost:8080") != nil)
  #expect(request("http://app.localhost.:8080") != nil)
  #expect(request("http://app.localhost.evil:8080") == nil)
}

@Test func websitePermissionRequestsAccept127LoopbackRange() {
  func request(_ origin: String) -> WebsitePermissionRequest? {
    WebsitePermissionRequest(
      id: "loopback", profileID: UUID(), tabID: UUID(),
      pageURL: URL(string: "http://127.0.0.2:8080/page")!,
      requestingOrigin: URL(string: origin)!, kinds: [.camera])
  }

  #expect(request("http://127.0.0.2:8080") != nil)
  #expect(request("http://127.255.255.254:8080") != nil)
  #expect(request("http://127.1:8080") != nil)
  #expect(request("http://128.0.0.1:8080") == nil)
  #expect(request("http://127.0.0.2.evil:8080") == nil)
}

@Test func websitePermissionRequestsAcceptExpandedIPv6Loopback() {
  func request(_ origin: String) -> WebsitePermissionRequest? {
    WebsitePermissionRequest(
      id: "ipv6", profileID: UUID(), tabID: UUID(),
      pageURL: URL(string: "http://[::1]:8080/page")!,
      requestingOrigin: URL(string: origin)!, kinds: [.camera])
  }

  #expect(request("http://[0:0:0:0:0:0:0:1]:8080") != nil)
  #expect(request("http://[0:0::1]:8080") != nil)
  #expect(request("http://[::2]:8080") == nil)
}

@Test func websitePermissionRequestsAcceptEveryForwardedKindAndOnlyMediaAreOneTime() {
  let request = WebsitePermissionRequest(
    id: "p2", profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://maps.example")!,
    requestingOrigin: URL(string: "https://maps.example")!,
    kinds: [.notifications, .location, .midi, .clipboard])
  #expect(request?.kinds == [.location, .notifications, .clipboard, .midi])
  #expect(WebsitePermissionKind(rawValue: "location") == .location)
  #expect(WebsitePermissionKind(rawValue: "protocolHandler") == .protocolHandler)
  #expect(WebsitePermissionKind(rawValue: "midi") == .midi)
  #expect(WebsitePermissionPersistence.forGrant(isPrivate: false, kinds: [.location]) == .profile)
  #expect(
    WebsitePermissionPersistence.forGrant(isPrivate: false, kinds: [.notifications, .midi])
      == .profile)
  #expect(!WebsitePermissionKind.protocolHandler.supportsOneTimeGrant)
  #expect(
    WebsitePermissionKind.allCases.filter(\.supportsOneTimeGrant) == [
      .camera, .microphone,
    ])
}

private let permissionFrame = "0123456789ABCDEF0123456789ABCDEF"

private func permissionPayload(
  kind: String = "websitePermissionRequested",
  schema: Any = 1,
  id: String = "permission-1",
  permissions: [String] = ["notifications"],
  tabID: UUID,
  windowID: String,
  profileID: UUID,
  frameID: Any? = permissionFrame
) -> [String: Any] {
  var payload: [String: Any] = [
    "schemaVersion": schema,
    "kind": kind,
    "id": id,
    "profileID": profileID.uuidString,
    "tabID": tabID.uuidString,
    "windowID": windowID,
    "pageURL": "https://notes.example/a",
    "origin": "https://notes.example/",
    "permissions": permissions,
  ]
  if let frameID { payload["frameID"] = frameID }
  return payload
}

@Test func websitePermissionEventsRejectUnknownKindDuplicateTabAndSchema() {
  let profile = UUID()
  let tab = UUID()
  let window = UUID().uuidString
  let known = Set([tab])
  let valid = WebsitePermissionEvent.request(
    from: permissionPayload(tabID: tab, windowID: window, profileID: profile),
    windowID: window, outstandingIDs: [], knownTabs: known)
  #expect(valid?.frameID == permissionFrame.lowercased())
  #expect(valid?.kinds == [.notifications])

  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(
        permissions: ["geolocation"], tabID: tab, windowID: window, profileID: profile),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(tabID: tab, windowID: window, profileID: profile),
      windowID: window, outstandingIDs: ["permission-1"], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(tabID: UUID(), windowID: window, profileID: profile),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(tabID: tab, windowID: UUID().uuidString, profileID: profile),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(schema: 2, tabID: tab, windowID: window, profileID: profile),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(schema: 1.5, tabID: tab, windowID: window, profileID: profile),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(schema: "1", tabID: tab, windowID: window, profileID: profile),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(tabID: tab, windowID: window, profileID: profile, frameID: nil),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)
  #expect(
    WebsitePermissionEvent.request(
      from: permissionPayload(
        tabID: tab, windowID: window, profileID: profile, frameID: "not-a-frame"),
      windowID: window, outstandingIDs: [], knownTabs: known) == nil)

  let media = WebsitePermissionEvent.request(
    from: permissionPayload(
      kind: "websiteMediaRequested", permissions: ["camera", "microphone"],
      tabID: tab, windowID: window, profileID: profile, frameID: nil),
    windowID: window, outstandingIDs: [], knownTabs: known)
  #expect(media?.frameID == nil)
  #expect(media?.kinds == [.camera, .microphone])
}

@Test func duplicatePermissionEventDoesNotDenyTheLiveRequest() throws {
  let profile = UUID()
  let tab = UUID()
  let window = UUID().uuidString
  let known = Set([tab])
  let payload = permissionPayload(tabID: tab, windowID: window, profileID: profile)
  let intake = WebsitePermissionEvent.intake(
    from: payload, windowID: window, outstandingIDs: ["permission-1"], knownTabs: known)
  #expect(intake == .ignoreDuplicate)
}

@Test func websitePermissionEventsRejectBooleanSchemaAndUnknownEventKind() throws {
  let profile = UUID()
  let tab = UUID()
  let window = UUID().uuidString
  let known = Set([tab])
  let boolean = Data(
    """
    {"schemaVersion":true,"kind":"websitePermissionRequested","id":"permission-9","profileID":"\(profile.uuidString)","tabID":"\(tab.uuidString)","windowID":"\(window)","pageURL":"https://notes.example/a","origin":"https://notes.example/","permissions":["notifications"],"frameID":"\(permissionFrame)"}
    """.utf8)
  let parsed = try #require(
    JSONSerialization.jsonObject(with: boolean) as? [String: Any])
  #expect(
    WebsitePermissionEvent.intake(
      from: parsed, windowID: window, outstandingIDs: [], knownTabs: known) == .deny)
  let unknown = WebsitePermissionEvent.intake(
    from: permissionPayload(
      kind: "notAPermissionEvent", tabID: tab, windowID: window, profileID: profile),
    windowID: window, outstandingIDs: [], knownTabs: known)
  #expect(unknown == .deny)
}

@Test func privateGrantsStayOnThisVisit() {
  #expect(
    WebsitePermissionPersistence.forGrant(isPrivate: true, kinds: [.notifications]) == .thisVisit)
  #expect(
    WebsitePermissionPersistence.forGrant(isPrivate: true, kinds: [.protocolHandler]) == .thisVisit)
  #expect(
    WebsitePermissionPersistence.forGrant(isPrivate: false, kinds: [.notifications]) == .profile)
  #expect(
    WebsitePermissionPersistence.forGrant(isPrivate: false, kinds: [.camera, .microphone])
      == .thisVisit)
}
