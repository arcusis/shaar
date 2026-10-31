// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func externalAppRequestAcceptsCanonicalEngineIDsAndRejectsInvalidIDs() {
  let page = URL(string: "https://example.com/page")!
  func request(id: String) -> ExternalAppRequest? {
    ExternalAppRequest(
      id: id, profileID: UUID(), tabID: UUID(), pageURL: page, scheme: "mailto",
      requestingOrigin: nil, applicationName: "Mail", windowID: "window-1")
  }

  #expect(request(id: "x1")?.id == "x1")
  #expect(request(id: "x123")?.id == "x123")
  for id in [
    "", "x", "x0", "x01", "X1", "y1", "x١", "x１", " x1", "x1\n", "+x1", "x+1", "x2147483648",
    "x12345678901",
  ] {
    #expect(request(id: id) == nil)
  }
}

@Test func externalAppRequestValidatesAndNormalizesSchemes() {
  func request(scheme: String) -> ExternalAppRequest? {
    ExternalAppRequest(
      id: "x1", profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://example.com")!,
      scheme: scheme, requestingOrigin: nil, applicationName: "App", windowID: "window-1")
  }

  #expect(request(scheme: "Web+Demo")?.scheme == "web+demo")
  for scheme in [
    "", "1mail", "mail:", "m ail", "m\nail", "máil", String(repeating: "a", count: 65),
    "http", "https", "file", "data", "javascript", "chrome", "chrome-extension", "about",
    "devtools",
  ] {
    #expect(request(scheme: scheme) == nil)
  }
}

@Test func externalAppRequestRequiresWebPageAndNormalizesOptionalOrigin() {
  let validPage = URL(string: "https://example.com/page")!
  func request(pageURL: URL = validPage, origin: String? = "HTTPS://Example.COM:443/")
    -> ExternalAppRequest?
  {
    ExternalAppRequest(
      id: "x1", profileID: UUID(), tabID: UUID(), pageURL: pageURL, scheme: "mailto",
      requestingOrigin: origin.flatMap(URL.init(string:)), applicationName: "App",
      windowID: "window-1")
  }

  #expect(request()?.requestingOrigin?.absoluteString == "https://example.com")
  #expect(request(origin: nil)?.requestingOrigin == nil)
  #expect(request(pageURL: URL(string: "file:///tmp/page")!) == nil)
  for origin in [
    "ftp://example.com", "https://user@example.com", "https://user:secret@example.com",
    "https://example.com/path", "https://example.com?query=1", "https://example.com#fragment",
    "https:///missing-host",
  ] {
    #expect(request(origin: origin) == nil)
  }
}

@Test func externalAppRequestTrimsAndBoundsApplicationNameAndWindowID() {
  func request(name: String?, windowID: String = "window-1") -> ExternalAppRequest? {
    ExternalAppRequest(
      id: "x1", profileID: UUID(), tabID: UUID(), pageURL: URL(string: "https://example.com")!,
      scheme: "mailto", requestingOrigin: nil, applicationName: name, windowID: windowID)
  }

  #expect(request(name: "  Mail  ")?.applicationName == "Mail")
  #expect(request(name: nil)?.canOpen == false)
  #expect(request(name: "   ")?.canOpen == false)
  #expect(request(name: " \n ") == nil)
  #expect(request(name: "a" + String(repeating: "é", count: 128)) == nil)
  #expect(request(name: "Mail\nApp") == nil)
  #expect(request(name: "Mail\u{0000}App") == nil)
  #expect(request(name: "Mail", windowID: "") == nil)
  #expect(request(name: "Mail", windowID: "window id") == nil)
  #expect(request(name: "Mail", windowID: "window\n1") == nil)
  #expect(request(name: "Mail", windowID: String(repeating: "w", count: 129)) == nil)
  #expect(request(name: "Mail", windowID: String(repeating: "w", count: 128)) != nil)
  #expect(request(name: String(repeating: "a", count: 256))?.applicationName?.utf8.count == 256)
  #expect(
    request(name: "   " + String(repeating: "a", count: 256) + "   ")?.applicationName?.utf8.count
      == 256)
  #expect(request(name: String(repeating: "a", count: 257)) == nil)
}

@Test func externalAppRequestMatchesOnlySelectedProfileTabAndPage() throws {
  let profile = BrowserProfile(name: "Shared")
  let otherProfile = BrowserProfile(name: "Other")
  let page = URL(string: "https://example.com/page")!
  let otherPage = URL(string: "https://example.com/other")!
  let selectedTab = BrowserTab(url: page)
  let otherTab = BrowserTab(url: otherPage)
  let selectedSpace = BrowserSpace(
    profileID: profile.id, name: "Selected", symbol: "house", tint: .lavender,
    tabs: [selectedTab], selectedTabID: selectedTab.id)
  let otherSpace = BrowserSpace(
    profileID: profile.id, name: "Other", symbol: "briefcase", tint: .ocean,
    tabs: [otherTab], selectedTabID: otherTab.id)
  let session = try BrowserSession(
    profiles: [profile, otherProfile], spaces: [selectedSpace, otherSpace],
    selectedSpaceID: selectedSpace.id)
  func request(profileID: UUID = profile.id, tabID: UUID = selectedTab.id, pageURL: URL = page)
    -> ExternalAppRequest
  {
    ExternalAppRequest(
      id: "x1", profileID: profileID, tabID: tabID, pageURL: pageURL, scheme: "mailto",
      requestingOrigin: nil, applicationName: "Mail", windowID: "window-1")!
  }

  #expect(request().matches(session))
  #expect(!request(profileID: otherProfile.id).matches(session))
  #expect(!request(tabID: otherTab.id).matches(session))
  #expect(!request(pageURL: otherPage).matches(session))
  var otherSpaceSelected = session
  otherSpaceSelected.selectSpace(otherSpace.id)
  #expect(!request().matches(otherSpaceSelected))
}
