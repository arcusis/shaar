import Foundation
import Testing
@testable import ArcusisBrowser

struct ExtensionPanelTests {
  @Test func listRouteIdentityIncludesProfileAndOptionalTab() {
    let profileID = UUID()
    let tabID = UUID()
    let route = ExtensionPanelRoute.list(profileID: profileID, tabID: tabID)

    #expect(route.id == "list-\(profileID)-\(tabID.uuidString)")
    #expect(
      route.id != ExtensionPanelRoute.list(profileID: profileID, tabID: nil).id)
    #expect(
      route.id != ExtensionPanelRoute.list(profileID: UUID(), tabID: tabID).id)
  }

  @Test func listRouteWithoutTabHasStableEmptyIdentity() {
    let profileID = UUID()

    #expect(
      ExtensionPanelRoute.list(profileID: profileID, tabID: nil).id == "list-\(profileID)-empty")
  }

  @Test func popupRouteUsesPopupIdentity() {
    let context = ExtensionPopupContext(
      id: "extension-popup-42", profileID: UUID(), tabID: UUID(),
      extensionID: "example.extension", name: "Example")

    #expect(ExtensionPanelRoute.popup(context).id == "extension-popup-42")
  }
}
