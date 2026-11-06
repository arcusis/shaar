// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func openSpaceButtonNamesItsDestinationInBothLanguages() {
  #expect(
    BrowserSettingsAccessibility.openSpaceLabel(name: "Research", language: .english)
      == "Open Research")
  #expect(
    BrowserSettingsAccessibility.openSpaceLabel(name: "Research", language: .hebrew)
      == "פתיחת המרחב \u{2068}Research\u{2069}")
}

@Test func disconnectButtonNamesTheAccountAndProviderInBothLanguages() {
  let account = ConnectedAccount(
    provider: .google, email: "alice@example.com", name: "Alice", photoURL: nil, photoData: nil)
  #expect(
    BrowserSettingsAccessibility.disconnectAccountLabel(account: account, language: .english)
      == "Disconnect alice@example.com from Google")
  #expect(
    BrowserSettingsAccessibility.disconnectAccountLabel(account: account, language: .hebrew)
      == "ניתוק \u{2068}alice@example.com\u{2069} מ-\u{2068}Google\u{2069}")
}

@Test func macSettingsButtonNamesItsPermissionInBothLanguages() {
  #expect(
    BrowserSettingsAccessibility.openPermissionSettingsLabel(name: "Camera", language: .english)
      == "Open Camera Settings")
  #expect(
    BrowserSettingsAccessibility.openPermissionSettingsLabel(name: "מצלמה", language: .hebrew)
      == "פתיחת הגדרות \u{2068}מצלמה\u{2069}")
}

@Test @MainActor func resetPermissionActionsAndConfirmationNameTheOriginInBothLanguages() {
  #expect(
    BrowserSettingsAccessibility.resetPermissionsLabel(
      origin: "https://example.test", language: .english)
      == "Reset permissions for https://example.test")
  #expect(
    BrowserSettingsAccessibility.resetPermissionsLabel(
      origin: "https://example.test", language: .hebrew)
      == "איפוס ההרשאות עבור \u{2068}https://example.test\u{2069}")
  #expect(
    ProfilePrivacyModel.resetPermissionsMessage(
      origin: "https://example.test", language: .english)
      == "Site permissions for https://example.test reset to defaults.")
  #expect(
    ProfilePrivacyModel.resetPermissionsMessage(
      origin: "https://example.test", language: .hebrew)
      == "הרשאות האתר עבור \u{2068}https://example.test\u{2069} אופסו לברירות המחדל.")
}

@Test func macOSPermissionsGuidanceUsesEnglishAndHebrewCatalogValues() {
  let key = "Websites can only use what macOS allows. If a site's request is blocked here, change it in System Settings."
  #expect(
    BrowserLocalization.string(key, table: "Settings", language: .english)
      == key)
  #expect(
    BrowserLocalization.string(key, table: "Settings", language: .hebrew)
      == "אתרים יכולים להשתמש רק בהרשאות ש‑macOS מאפשרת. אם בקשת אתר חסומה כאן, יש לשנות זאת בהגדרות המערכת.")
}

@Test @MainActor func profilePaneMasterDetailFitsLightAndDarkAppearances() {
  let id = UUID()
  let selectedProfileID = Binding<UUID?>(get: { id }, set: { _ in })
  let view = BrowserSettingsView(
    profiles: [
      BrowserSettingsProfile(
        id: id, name: "Work",
        spaces: [BrowserSettingsSpace(id: UUID(), name: "Research", symbol: "book")],
        canChooseDownloadDirectory: true)
    ],
    searchEngines: [BrowserSettingsChoice(id: "google", title: "Google")],
    selectedProfileID: selectedProfileID,
    sidebarInitiallyVisible: .constant(true), selectedSearchEngine: .constant("google"),
    initialSection: .profiles)
  let host = NSHostingView(rootView: view)
  host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)

  for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
    host.appearance = appearance
    host.layoutSubtreeIfNeeded()
    #expect(host.bounds.width == 720)
    #expect(host.bounds.height == 560)
    #expect(host.fittingSize.width >= 600)
    #expect(host.fittingSize.height >= 440)
  }
}

@Test @MainActor func reopeningSettingsForAnotherProfileSelectsRequestedProfile() throws {
  let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
  let first = try #require(workspace.workspace.catalog.profiles.first?.id)
  let second = try workspace.createProfile(name: "Second")
  let controller = BrowserSettingsController(
    workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
  defer { controller.close() }

  controller.show(for: first)
  #expect(controller.selectedProfileID == first)
  controller.show(for: second)
  #expect(controller.selectedProfileID == second)
  controller.show()
  #expect(controller.selectedProfileID == second)
}

@Test func inlineProfileSaveRejectsBlankNameEdits() {
  #expect(!ProfileNameEditPolicy.canSave(nil))
  #expect(!ProfileNameEditPolicy.canSave(" \n "))
  #expect(ProfileNameEditPolicy.canSave(" Work "))
}
