// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor @Test func addExtensionsOpensInTheActiveSpaceForItsProfile() throws {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let createdSpaceID = session.addSpace(name: "Second", sharingProfile: profileID)
  let activeSpaceID = try #require(createdSpaceID)
  session.selectSpace(activeSpaceID)
  let workspace = try BrowserWorkspaceStore(initialSession: session)
  let state = BrowserSettingsState(workspace: workspace, preferences: BrowserPreferencesStore())

  state.openExtensions(for: profileID)

  let store = try #require(workspace.stores.values.first)
  #expect(store.session.selectedSpaceID == activeSpaceID)
  #expect(store.session.selectedSpace.tabs.contains { $0.url == BrowserExtension.storeCatalogURL })
}
