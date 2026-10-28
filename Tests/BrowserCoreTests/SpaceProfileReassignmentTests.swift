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
}
