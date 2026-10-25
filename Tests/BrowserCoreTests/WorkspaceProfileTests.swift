import BrowserCore
import Foundation
import Testing

@Suite struct WorkspaceProfileTests {
  @Test func profileEditsPreserveWindowAndLiveTabIdentity() throws {
    let profile = BrowserProfile(name: "Original")
    let tab = BrowserTab(url: URL(string: "https://example.com")!)
    let space = BrowserSpace(
      profileID: profile.id, name: "Space", symbol: "s", tint: .ocean, tabs: [tab])
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    var workspace = try BrowserWorkspace(session: session)
    let windowID = workspace.windows[0].id

    let addedID = try workspace.createProfile(name: "Unused")
    try workspace.renameProfile(profile.id, name: "Renamed")

    #expect(workspace.catalog.profiles.first { $0.id == profile.id }?.name == "Renamed")
    #expect(workspace.catalog.profiles.first { $0.id == addedID }?.name == "Unused")
    #expect(workspace.windows[0].id == windowID)
    #expect(workspace.windows[0].session.selectedSpaceID == space.id)
    #expect(workspace.windows[0].session.selectedSpace.tabs.map(\.id) == [tab.id])
    #expect(workspace.windows[0].session.profiles.map(\.id) == [profile.id, addedID])
    #expect(throws: WorkspaceError.self) { try workspace.renameProfile(UUID(), name: "Unknown") }
    #expect(throws: WorkspaceError.self) { try workspace.createProfile(name: "  ") }
  }
}
