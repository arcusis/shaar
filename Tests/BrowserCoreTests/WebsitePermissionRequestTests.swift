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

@Test func websitePermissionRequestsAcceptEveryForwardedKindAndOnlyMediaAndLocationAreOneTime() {
  let request = WebsitePermissionRequest(
    id: "p2", profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://maps.example")!,
    requestingOrigin: URL(string: "https://maps.example")!,
    kinds: [.notifications, .location, .clipboard])
  #expect(request?.kinds == [.location, .notifications, .clipboard])
  #expect(WebsitePermissionKind(rawValue: "location") == .location)
  #expect(
    WebsitePermissionKind.allCases.filter(\.supportsOneTimeGrant) == [
      .camera, .microphone, .location,
    ])
}
