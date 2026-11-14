// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserSettingsControllerTests {
  @Test func siteAccessUsesFocusedWindowOnlyForItsSelectedProfile() throws {
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let firstWindowID = try #require(workspace.workspace.windows.first?.id)
    let secondWindowID = try workspace.newWindow(from: firstWindowID)
    let firstStore = try #require(workspace.stores[firstWindowID])
    let secondStore = try #require(workspace.stores[secondWindowID])
    let firstProfile = firstStore.session.profiles[0].id
    let secondProfile = try #require(firstStore.session.profiles.dropFirst().first?.id)
    let secondSpace = try #require(
      secondStore.session.spaces.first { $0.profileID == secondProfile }?.id)
    secondStore.perform(.space(secondSpace))
    try workspace.focusWindow(firstWindowID)

    let state = BrowserSettingsState(
      workspace: workspace, preferences: BrowserPreferencesStore())

    #expect(
      state.browserStoreForSiteAccess(profileID: firstProfile, keyWindow: nil) === firstStore)
    #expect(
      state.browserStoreForSiteAccess(profileID: secondProfile, keyWindow: nil) == nil)
  }
}
