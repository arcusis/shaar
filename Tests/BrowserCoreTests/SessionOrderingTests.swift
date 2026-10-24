import BrowserCore
import Foundation
import Testing

private func orderedSession() throws -> BrowserSession {
  let a = BrowserProfile(name: "A")
  let b = BrowserProfile(name: "B")
  func tab(_ name: String, pinned: Bool = false) -> BrowserTab {
    BrowserTab(url: URL(string: "https://example.com/\(name)")!, title: name, isPinned: pinned)
  }
  let tabs = [tab("p1", pinned: true), tab("p2", pinned: true), tab("r1"), tab("r2")]
  let spaces = [
    BrowserSpace(
      profileID: a.id, name: "A", symbol: "house", tint: .lavender, tabs: tabs,
      selectedTabID: tabs[2].id),
    BrowserSpace(profileID: b.id, name: "B", symbol: "briefcase", tint: .ocean, tabs: [tab("b")]),
    BrowserSpace(
      profileID: a.id, name: "Shared", symbol: "square.stack", tint: .forest,
      tabs: [tab("s1"), tab("s2")]),
  ]
  return try BrowserSession(profiles: [a, b], spaces: spaces, selectedSpaceID: spaces[0].id)
}

@Test func selectedTabMoveFollowsItsLiveIdentityWithinTheSameProfile() throws {
  var session = try orderedSession()
  let source = session.spaces[0]
  let destination = session.spaces[2]
  let other = session.spaces[1]
  let moving = source.tabs[2]
  let moved = session.moveTab(
    moving.id, from: source.id, to: destination.id, before: destination.tabs[1].id)
  #expect(moved)
  #expect(session.selectedSpaceID == destination.id)
  #expect(session.selectedSpace.selectedTab == moving)
  #expect(
    session.selectedSpace.tabs.map(\.id) == [
      destination.tabs[0].id, moving.id, destination.tabs[1].id,
    ])
  #expect(session.spaces[0].selectedTabID == source.tabs[3].id)
  #expect(session.spaces[1] == other)
  #expect(session.profiles.count == 2)
  try session.validate()
}

@Test func differentProfilesInvalidAnchorsAndStaleSourcesCannotMoveTabs() throws {
  var session = try orderedSession()
  let a = session.spaces[0]
  let b = session.spaces[1]
  let shared = session.spaces[2]
  let before = session
  let rejected = [
    session.moveTab(a.tabs[0].id, from: a.id, to: b.id),
    session.moveTab(a.tabs[0].id, from: a.id, to: shared.id, before: shared.tabs[0].id),
    session.moveTab(a.tabs[2].id, from: a.id, to: shared.id, before: UUID()),
    session.moveTab(a.tabs[2].id, from: b.id, to: shared.id),
  ]
  #expect(rejected == [false, false, false, false])
  #expect(session == before)
  let accepted = session.moveTab(a.tabs[2].id, from: a.id, to: shared.id)
  #expect(accepted)
  let moved = session
  let stale = session.moveTab(a.tabs[2].id, from: a.id, to: shared.id)
  #expect(!stale)
  #expect(session == moved)
}

@Test func reorderAndPinChangesPreserveSelectionAndVisibleGroupOrder() throws {
  var session = try orderedSession()
  let a = session.spaces[0]
  let selected = a.selectedTabID
  let reordered = session.moveTab(a.tabs[3].id, from: a.id, to: a.id, before: a.tabs[2].id)
  #expect(reordered)
  #expect(session.selectedSpace.tabs.filter { !$0.isPinned }.map(\.title) == ["r2", "r1"])
  session.togglePin(a.tabs[3].id)
  #expect(session.selectedSpace.tabs.filter(\.isPinned).map(\.title) == ["p1", "p2", "r2"])
  session.togglePin(a.tabs[0].id)
  #expect(session.selectedSpace.tabs.filter { !$0.isPinned }.map(\.title) == ["r1", "p1"])
  #expect(session.selectedSpace.selectedTabID == selected)
  let before = session
  let unchanged = session.moveTab(a.tabs[2].id, from: a.id, to: a.id, before: a.tabs[2].id)
  #expect(!unchanged)
  #expect(session == before)
}

@Test func backgroundMovesAndSpaceOrderingKeepTheActiveAccountUntouched() throws {
  var session = try orderedSession()
  let a = session.spaces[0]
  let b = session.spaces[1]
  let shared = session.spaces[2]
  session.selectSpace(b.id)
  let moved = session.moveTab(a.tabs[2].id, from: a.id, to: shared.id)
  #expect(moved)
  #expect(session.selectedSpace == b)
  #expect(session.spaces[2].selectedTabID == shared.selectedTabID)
  let reordered = session.moveSpace(shared.id, before: a.id)
  #expect(reordered)
  #expect(session.spaces.map(\.id) == [shared.id, a.id, b.id])
  #expect(session.selectedSpace == b)
  session.cycleSpace(by: 1)
  #expect(session.selectedSpace.id == shared.id)
  let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session))
  #expect(restored == session)
}

@Test func repeatedMovesKeepAllDocumentsAndOriginalProfileOwners() throws {
  var session = try orderedSession()
  let originals = Dictionary(
    uniqueKeysWithValues: session.spaces.flatMap { space in
      space.tabs.map { ($0.id, (space.profileID, $0.url)) }
    })
  let a = session.spaces[0].id
  let shared = session.spaces[2].id
  for index in 0..<40 {
    let source = index.isMultiple(of: 2) ? a : shared
    let destination = index.isMultiple(of: 2) ? shared : a
    let space = try #require(session.spaces.first { $0.id == source })
    let tab = try #require(space.tabs.first)
    let moved = session.moveTab(
      tab.id, from: source, to: destination, pinned: index.isMultiple(of: 3))
    #expect(moved)
    try session.validate()
    #expect(session.spaces.flatMap(\.tabs).count == originals.count)
    for current in session.spaces {
      for tab in current.tabs {
        #expect(originals[tab.id]?.0 == current.profileID)
        #expect(originals[tab.id]?.1 == tab.url)
      }
    }
  }
}
