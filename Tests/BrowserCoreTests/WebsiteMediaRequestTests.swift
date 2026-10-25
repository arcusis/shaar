import BrowserCore
import Foundation
import Testing

@Test func websiteMediaRequestsRequireSecureOriginsAndKnownCapabilities() throws {
  let page = URL(string: "https://meet.google.com/example")!
  let profile = UUID()
  let tab = UUID()
  func request(origin: String, kinds: [WebsiteMediaKind] = [.camera, .microphone])
    -> WebsiteMediaRequest?
  {
    WebsiteMediaRequest(
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
  #expect(WebsiteMediaKind(rawValue: "screen") == nil)
  #expect(WebsiteMediaKind(rawValue: "cameraPanTiltZoom") == nil)
}
