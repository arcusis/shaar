import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct BrowserSettingsProfileTests {
  @Test func settingsCreatesUnusedProfileAndRenamesExistingProfile() throws {
    let profile = BrowserProfile(name: "Original")
    let space = BrowserSpace(profileID: profile.id, name: "Space", symbol: "s", tint: .ocean)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let workspace = try BrowserWorkspaceStore(initialSession: session)
    let settings = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    let originalWindowID = workspace.workspace.windows[0].id

    settings.show(for: profile.id)
    let addedID = try #require(settings.createProfile(name: "Unused"))
    let added = try #require(settings.profiles.first { $0.id == addedID })
    #expect(added.spaceCount == 0)
    #expect(settings.renameProfile(profile.id, name: "Renamed"))
    #expect(settings.profiles.first { $0.id == profile.id }?.name == "Renamed")
    #expect(workspace.workspace.windows[0].id == originalWindowID)
    #expect(workspace.stores[originalWindowID]?.session.selectedSpaceID == space.id)
    #expect(settings.createProfile(name: " ") == nil)
    settings.close()
  }
}
