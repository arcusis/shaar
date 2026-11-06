// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct CommandPanelKeyboardTests {
  @Test func tabAndShiftTabTraverseSearchAndFilters() {
    #expect(CommandPanelKeyboard.nextFocus(from: nil, by: 1) == .tabs)
    #expect(CommandPanelKeyboard.nextFocus(from: .tabs, by: 1) == .history)
    #expect(CommandPanelKeyboard.nextFocus(from: .actions, by: 1) == nil)
    #expect(CommandPanelKeyboard.nextFocus(from: nil, by: -1) == .actions)
    #expect(CommandPanelKeyboard.nextFocus(from: .history, by: -1) == .tabs)
  }

  @Test func horizontalArrowsStayWithinFourFilters() {
    #expect(
      CommandPanelKeyboard.nextFilter(
        from: .tabs, movingRight: false, layoutDirection: .leftToRight) == .actions)
    #expect(
      CommandPanelKeyboard.nextFilter(
        from: .actions, movingRight: true, layoutDirection: .leftToRight) == .tabs)
    #expect(
      CommandPanelKeyboard.nextFilter(
        from: .history, movingRight: true, layoutDirection: .leftToRight) == .bookmarks)
    #expect(
      CommandPanelKeyboard.nextFilter(
        from: .history, movingRight: false, layoutDirection: .rightToLeft) == .bookmarks)
    #expect(
      CommandPanelKeyboard.nextFilter(
        from: .history, movingRight: true, layoutDirection: .rightToLeft) == .tabs)
  }

  @Test func providerKeywordRequiresExplicitTabActivation() {
    let store = BrowserStore()
    let profileID = store.session.selectedSpace.profileID
    store.preferences.setAccount(
      ConnectedAccount(provider: .google, email: "work@example.test"), for: profileID)
    store.showCommand()
    store.commandQuery = "gmail project"
    #expect(!store.activateCommandProviderKeyword())
    #expect(store.commandProviderKeyword == nil)
    store.commandQuery = "gmail"
    #expect(store.activateCommandProviderKeyword())
    #expect(store.commandQuery == "gmail ")
    #expect(store.commandFilter == .actions)
    store.commandQuery = "gmail project"
    #expect(store.selectedCommandResult?.title == "Search Gmail for “project”")
    store.commandFilter = nil
    #expect(store.commandProviderKeyword == nil)
  }
}
