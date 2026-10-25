import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserSettingsIntegrationTests {
  @Test func profileSearchChoicesReachIndependentAndSharedStores() throws {
    let fixture = fixture()
    let manager = try BrowserWorkspaceStore(initialSession: fixture.session)
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferences = BrowserPreferencesStore(
      fileURL: directory.appending(path: "preferences.json"))
    for store in manager.stores.values { store.usePreferences(preferences) }
    let first = manager.stores[firstID]!
    let shared = manager.stores[secondID]!

    preferences.setSearchEngine(.bing, for: fixture.alpha.id)
    preferences.setSearchEngine(.duckDuckGo, for: fixture.beta.id)
    first.commandQuery = "alpha search term"
    shared.commandQuery = "shared search term"
    shared.perform(.space(fixture.betaSpace.id))

    #expect(openResult(in: first)?.host() == "www.bing.com")
    #expect(openResult(in: shared)?.host() == "duckduckgo.com")
    first.commandQuery = "shared profile term"
    #expect(openResult(in: first)?.host() == "www.bing.com")
  }

  @Test func settingsChoicesPreserveWorkspaceAndRejectStaleProfiles() throws {
    let fixture = fixture()
    let manager = try BrowserWorkspaceStore(initialSession: fixture.session)
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferences = BrowserPreferencesStore(
      fileURL: directory.appending(path: "preferences.json"))
    for store in manager.stores.values { store.usePreferences(preferences) }
    let before = manager.workspace
    let controller = BrowserSettingsController(
      workspace: manager, preferences: preferences, presentation: .hiddenProbe)

    #expect(controller.profiles.first { $0.id == fixture.alpha.id }?.spaceCount == 2)
    #expect(controller.profiles.first { $0.id == fixture.beta.id }?.spaceCount == 1)
    controller.show(for: fixture.alpha.id)
    #expect(controller.selectedProfileID == fixture.alpha.id)
    #expect(controller.selectProfile(fixture.beta.id))
    #expect(controller.selectSearchEngine(BrowserSearchEngine.duckDuckGo.rawValue))
    #expect(!controller.selectSearchEngine(BrowserSearchEngine.bing.rawValue, for: UUID()))
    #expect(preferences.searchEngine(for: fixture.beta.id) == .duckDuckGo)
    #expect(controller.sidebarInitiallyVisible)
    controller.setSidebarInitiallyVisible(false)
    #expect(!preferences.sidebarInitiallyVisible)
    #expect(manager.workspace == before)
    #expect(manager.stores[firstID]?.session == before.window(firstID)?.session)
    #expect(manager.stores[secondID]?.session == before.window(secondID)?.session)

    let window = try #require(controller.window)
    #expect(!window.isVisible)
    controller.close()
    controller.show(for: fixture.alpha.id)
    #expect(controller.window === window && !window.isVisible)
    #expect(controller.selectedProfileID == fixture.beta.id)
    controller.close()
  }

  @Test func settingsStartUnselectedWithoutActiveProfileAndRefreshCatalogCounts() throws {
    let fixture = fixture()
    let manager = try BrowserWorkspaceStore(initialSession: fixture.session)
    let preferences = BrowserPreferencesStore()
    let controller = BrowserSettingsController(
      workspace: manager, preferences: preferences, presentation: .hiddenProbe)

    controller.show()
    #expect(controller.selectedProfileID == nil)
    #expect(
      manager.stores.values.first?.createSpace(
        name: "Alpha Three", sharingProfile: fixture.alpha.id, tint: .forest) == true)
    #expect(controller.profiles.first { $0.id == fixture.alpha.id }?.spaceCount == 3)
    for id in Array(manager.stores.keys) { try manager.removeWindow(id) }
    #expect(manager.workspace.windows.isEmpty)
    #expect(controller.profiles.first { $0.id == fixture.alpha.id }?.spaceCount == 3)
    controller.close()
  }

  @Test func sidebarDefaultAppliesToAttachedWindowStores() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture().session)
    let preferences = BrowserPreferencesStore()
    preferences.setSidebarInitiallyVisible(false)
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    manager.stores[secondID]?.usePreferences(preferences)
    #expect(manager.stores[secondID]?.sidebarIsVisible == false)
    #expect(manager.stores[firstID]?.sidebarIsVisible == true)
  }

  @Test func settingsWindowDoesNotRetainItsController() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture().session)
    let preferences = BrowserPreferencesStore()
    weak var weakController: BrowserSettingsController?
    var retainedWindow: AnyObject?
    do {
      let controller = BrowserSettingsController(
        workspace: manager, preferences: preferences, presentation: .hiddenProbe)
      controller.show()
      weakController = controller
      retainedWindow = controller.window
    }
    #expect(weakController == nil)
    #expect(retainedWindow != nil)
  }

  private func openResult(in store: BrowserStore) -> URL? {
    store.results.compactMap {
      if case .open(let url) = $0.action { return url }
      return nil
    }.first
  }

  private func fixture() -> (
    session: BrowserSession, alpha: BrowserProfile, beta: BrowserProfile, betaSpace: BrowserSpace
  ) {
    let alpha = BrowserProfile(name: "Alpha")
    let beta = BrowserProfile(name: "Beta")
    let alphaSpace = BrowserSpace(
      profileID: alpha.id, name: "Alpha One", symbol: "a", tint: .rose)
    let alphaSpaceTwo = BrowserSpace(
      profileID: alpha.id, name: "Alpha Two", symbol: "b", tint: .forest)
    let betaSpace = BrowserSpace(
      profileID: beta.id, name: "Beta One", symbol: "c", tint: .ocean)
    let session = try! BrowserSession(
      profiles: [alpha, beta], spaces: [alphaSpace, alphaSpaceTwo, betaSpace],
      selectedSpaceID: alphaSpace.id)
    return (session, alpha, beta, betaSpace)
  }
}
