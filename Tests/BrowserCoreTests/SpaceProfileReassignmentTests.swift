// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Suite struct SpaceProfileReassignmentTests {
  @Test func reassignmentPreservesTabsAcrossWindowsAndRoundTrip() throws {
    var session = BrowserSession.fresh()
    let spaceID = session.selectedSpaceID
    let target = session.profiles[1].id
    let opened = session.open(URL(string: "https://example.test/one")!)
    let tab = try #require(opened)
    session.togglePin(tab)
    _ = session.open(URL(string: "https://example.test/two")!)
    var workspace = try BrowserWorkspace(session: session)
    let first = workspace.windows[0].id
    let second = try workspace.addWindow(from: first)
    let previous = workspace.windows.map(\.session)
    let changed = try workspace.setSpaceProfile(spaceID, to: target)
    #expect(changed)
    for (window, before) in zip(workspace.windows, previous) {
      let space = try #require(window.session.spaces.first { $0.id == spaceID })
      let original = try #require(before.spaces.first { $0.id == spaceID })
      #expect(space.profileID == target)
      #expect(space.tabs == original.tabs)
      for tab in space.tabs { #expect(window.session.profileID(forTabID: tab.id) == target) }
    }
    #expect(workspace.window(second) != nil)
    let data = try JSONEncoder().encode(workspace)
    #expect(try JSONDecoder().decode(BrowserWorkspace.self, from: data) == workspace)
    let beforeInvalid = workspace
    let rejected = try workspace.setSpaceProfile(spaceID, to: UUID())
    #expect(!rejected)
    #expect(workspace == beforeInvalid)
  }
  @Test func deletingProfileReassignsSpacesAndRejectsInvalidDestinations() throws {
    var workspace = try BrowserWorkspace(session: .fresh())
    let source = workspace.catalog.profiles[0].id
    let destination = workspace.catalog.profiles[1].id
    let spaces = workspace.catalog.spaces.filter { $0.profileID == source }.map(\.id)
    _ = try workspace.addWindow(from: workspace.windows[0].id)
    let original = workspace
    #expect(throws: (any Error).self) {
      try workspace.deleteProfile(source, movingSpacesTo: UUID())
    }
    #expect(workspace == original)
    try workspace.deleteProfile(source, movingSpacesTo: destination)
    #expect(!workspace.catalog.profiles.contains { $0.id == source })
    for id in spaces {
      #expect(workspace.catalog.spaces.first { $0.id == id }?.profileID == destination)
      for window in workspace.windows {
        #expect(window.session.spaces.first { $0.id == id }?.profileID == destination)
      }
    }
    try workspace.validate()
    let after = workspace
    #expect(throws: (any Error).self) {
      try workspace.deleteProfile(destination, movingSpacesTo: source)
    }
    #expect(workspace == after)
  }
}
