// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func favoritePageConsentMatchesSelectedPageIdentityAndOwnerProfile() throws {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let addedFavoriteID = session.addFavorite(
    profileID: profileID, originalURL: URL(string: "https://favorite.example/start")!)
  let favoriteID = try #require(addedFavoriteID)
  let page = try #require(session.favoritePages.first { $0.favoriteID == favoriteID })
  let selectedFavorite = session.selectFavorite(favoriteID, in: session.selectedSpaceID)
  #expect(selectedFavorite)
  let source = page.tab.url
  let extensionInfo = try #require(
    BrowserExtension(id: String(repeating: "a", count: 32), name: "Example", version: "1"))

  func extensionRequest(
    profileID: UUID = profileID, tabID: UUID = page.tab.id, sourceURL: URL = source
  ) -> ExtensionInstallRequest {
    ExtensionInstallRequest(
      id: "install1", profileID: profileID, tabID: tabID, sourceURL: sourceURL,
      browserExtension: extensionInfo, kind: .install, permissions: [])!
  }
  func mediaRequest(
    profileID: UUID = profileID, tabID: UUID = page.tab.id, pageURL: URL = source
  ) -> WebsitePermissionRequest {
    WebsitePermissionRequest(
      id: "media1", profileID: profileID, tabID: tabID, pageURL: pageURL,
      requestingOrigin: URL(string: "https://favorite.example")!, kinds: [.camera])!
  }
  func externalRequest(
    profileID: UUID = profileID, tabID: UUID = page.tab.id, pageURL: URL = source
  ) -> ExternalAppRequest {
    ExternalAppRequest(
      id: "x1", profileID: profileID, tabID: tabID, pageURL: pageURL, scheme: "webcal",
      requestingOrigin: URL(string: "https://favorite.example")!, applicationName: "Calendar",
      windowID: "window-1")!
  }

  for matches in [
    extensionRequest().matches(session), mediaRequest().matches(session),
    externalRequest().matches(session),
  ] {
    #expect(matches)
  }
  let wrongPageID = UUID()
  let otherProfileID = UUID()
  let otherURL = URL(string: "https://other.example/page")!
  for matches in [
    extensionRequest(tabID: wrongPageID).matches(session),
    mediaRequest(tabID: wrongPageID).matches(session),
    externalRequest(tabID: wrongPageID).matches(session),
    extensionRequest(profileID: otherProfileID).matches(session),
    mediaRequest(profileID: otherProfileID).matches(session),
    externalRequest(profileID: otherProfileID).matches(session),
    extensionRequest(sourceURL: otherURL).matches(session),
    mediaRequest(pageURL: otherURL).matches(session),
    externalRequest(pageURL: otherURL).matches(session),
  ] {
    #expect(!matches)
  }

  let ordinaryTabID = session.open(URL(string: "https://ordinary.example/page")!)
  #expect(ordinaryTabID != nil)
  #expect(session.selectedPage?.tab.id != page.tab.id)
  #expect(!extensionRequest().matches(session))
  #expect(!mediaRequest().matches(session))
  #expect(!externalRequest().matches(session))
}

@Test func consentMatchingKeepsOrdinarySelectedTabBehavior() throws {
  let profile = BrowserProfile(name: "Default")
  let pageURL = URL(string: "https://ordinary.example/page")!
  let tab = BrowserTab(url: pageURL)
  let space = BrowserSpace(
    profileID: profile.id, name: "Ordinary", symbol: "house", tint: .lavender,
    tabs: [tab], selectedTabID: tab.id)
  let session = try BrowserSession(profiles: [profile], spaces: [space], selectedSpaceID: space.id)
  let extensionInfo = try #require(
    BrowserExtension(id: String(repeating: "b", count: 32), name: "Example", version: "1"))
  let install = try #require(
    ExtensionInstallRequest(
      id: "install1", profileID: profile.id, tabID: tab.id, sourceURL: pageURL,
      browserExtension: extensionInfo, kind: .install, permissions: []))
  let media = try #require(
    WebsitePermissionRequest(
      id: "media1", profileID: profile.id, tabID: tab.id, pageURL: pageURL,
      requestingOrigin: URL(string: "https://ordinary.example")!, kinds: [.microphone]))
  let external = try #require(
    ExternalAppRequest(
      id: "x1", profileID: profile.id, tabID: tab.id, pageURL: pageURL, scheme: "webcal",
      requestingOrigin: URL(string: "https://ordinary.example")!, applicationName: "Calendar",
      windowID: "window-1"))

  #expect(install.matches(session))
  #expect(media.matches(session))
  #expect(external.matches(session))
}
