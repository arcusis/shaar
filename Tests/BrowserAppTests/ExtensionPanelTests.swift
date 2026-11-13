// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct ExtensionPanelTests {
  @Test func listRouteIdentityIncludesProfileAndOptionalTab() {
    let profileID = UUID()
    let tabID = UUID()
    let list = ExtensionPanelRoute.list(profileID: profileID, tabID: nil)
    let sameList = ExtensionPanelRoute.list(profileID: profileID, tabID: nil)
    let tabList = ExtensionPanelRoute.list(profileID: profileID, tabID: tabID)
    let otherProfile = ExtensionPanelRoute.list(profileID: UUID(), tabID: nil)

    #expect(tabList.id == "list-\(profileID)-\(tabID.uuidString)")
    #expect(list.id == sameList.id)
    #expect(list.id != tabList.id)
    #expect(list.id != otherProfile.id)
    #expect(tabList.id.contains(tabID.uuidString))
  }

  @Test func listRouteWithoutTabHasStableEmptyIdentity() {
    let profileID = UUID()

    #expect(
      ExtensionPanelRoute.list(profileID: profileID, tabID: nil).id == "list-\(profileID)-empty")
  }

  @Test func popupRouteUsesPopupIdentity() {
    let popupID = "extension-popup-42"
    let context = ExtensionPopupContext(
      id: popupID, profileID: UUID(), tabID: UUID(),
      extensionID: "example.extension", name: "Example")

    #expect(ExtensionPanelRoute.popup(context).id == popupID)
  }
}
