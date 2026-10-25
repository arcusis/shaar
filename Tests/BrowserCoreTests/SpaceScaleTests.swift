import Foundation
import Testing

@testable import BrowserCore

@Test func hundredSpacesWithThreeHundredTabsRoundTripSelectionPinsAndOwners() throws {
  let profiles = (0..<10).map { BrowserProfile(name: "Account \($0)") }
  let spaces = (0..<100).map { spaceIndex -> BrowserSpace in
    let profile = profiles[spaceIndex % profiles.count]
    let tabs = (0..<300).map { tabIndex in
      BrowserTab(
        url: URL(string: "https://example.com/space-\(spaceIndex)/tab-\(tabIndex)")!,
        title: "Space \(spaceIndex) tab \(tabIndex)", isPinned: tabIndex.isMultiple(of: 10))
    }
    return BrowserSpace(
      profileID: profile.id, name: "Space \(spaceIndex)", symbol: "square.stack",
      tint: SpaceTint.allCases[spaceIndex % SpaceTint.allCases.count], tabs: tabs,
      selectedTabID: tabs[spaceIndex % tabs.count].id)
  }
  let selectedSpace = spaces[73]
  let session = try BrowserSession(
    profiles: profiles, spaces: spaces, selectedSpaceID: selectedSpace.id)

  let sessionData = try JSONEncoder().encode(session)
  let restored = try JSONDecoder().decode(BrowserSession.self, from: sessionData)
  try restored.validate()
  #expect(restored.spaces.count == 100)
  #expect(restored.spaces.allSatisfy { $0.tabs.count == 300 })
  #expect(restored.selectedSpaceID == selectedSpace.id)
  #expect(restored.selectedSpace.selectedTabID == selectedSpace.selectedTabID)
  #expect(restored.spaces.map(\.id) == spaces.map(\.id))
  for (actual, expected) in zip(restored.spaces, spaces) {
    #expect(actual.profileID == expected.profileID)
    #expect(actual.selectedTabID == expected.selectedTabID)
    #expect(actual.tabs.map(\.id) == expected.tabs.map(\.id))
    #expect(actual.tabs.map(\.isPinned) == expected.tabs.map(\.isPinned))
    #expect(actual.tabs.map(\.url) == expected.tabs.map(\.url))
  }

  let workspace = try BrowserWorkspace(session: restored)
  let workspaceData = try JSONEncoder().encode(workspace)
  let restoredWorkspace = try JSONDecoder().decode(BrowserWorkspace.self, from: workspaceData)
  try restoredWorkspace.validate()
  #expect(restoredWorkspace.catalog.spaces.count == 100)
  #expect(restoredWorkspace.windows[0].session == restored)
  #expect(restoredWorkspace.windows[0].pins.count == 3_000)
  let pinIDsByTab = Dictionary(
    uniqueKeysWithValues: restoredWorkspace.windows[0].pins.map { ($0.tabID, $0.pinID) })
  for space in restoredWorkspace.windows[0].session.spaces {
    #expect(space.tabs.count == 300)
    #expect(
      restoredWorkspace.catalog.spaces.first { $0.id == space.id }?.profileID == space.profileID)
    #expect(
      space.tabs.allSatisfy { tab in
        guard let pinID = pinIDsByTab[tab.id] else { return !tab.isPinned }
        return tab.isPinned && pinID == tab.id
          && restoredWorkspace.catalog.spaces.first { $0.id == space.id }?.tabs.contains {
            $0.id == pinID
          } == true
      })
  }
}
