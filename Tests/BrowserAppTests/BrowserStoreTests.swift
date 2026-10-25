import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreTests {
  @Test func nativeCloseWaitsForEngineBeforeRemovingTheTab() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com")!))
    let tab = try #require(store.session.selectedSpace.selectedTabID)
    let owner = store.session.selectedSpace
    var requested: UUID?
    store.onCloseTab = { requested = $0 }
    store.closeTab(tab)
    #expect(requested == tab)
    #expect(store.session.selectedSpace.selectedTabID == tab)
    store.cycleSpace(by: 1)
    let current = store.session.selectedSpaceID
    store.nativeTabClosed(tab)
    #expect(store.session.selectedSpaceID == current)
    #expect(!store.session.spaces.flatMap(\.tabs).contains { $0.id == tab })
    #expect(store.session.closedTabs.first?.spaceID == owner.id)
    #expect(store.session.closedTabs.first?.profileID == owner.profileID)
    #expect(!store.canReopenClosedTab)
  }

  @Test func openingAndCancelingLauncherDoesNotCreateTabsOrPersistChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    let before = store.session
    let savedBefore = try Data(contentsOf: file.url)
    store.showCommand()
    store.commandQuery = "example.com"
    store.dismissCommand()
    #expect(store.session == before)
    #expect(try Data(contentsOf: file.url) == savedBefore)
  }

  @Test func firstLaunchPersistsProfileIDsBeforeAnyNavigation() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let first = BrowserStore(sessionFile: file)
    let second = BrowserStore(sessionFile: file)
    #expect(second.session == first.session)
    #expect(second.session.profiles.map(\.id) == first.session.profiles.map(\.id))
    #expect(second.session.spaces.allSatisfy { $0.tabs.isEmpty })
  }

  @Test func spaceEditsPersistWithoutReassigningTheProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    let profile = store.session.selectedSpace.profileID
    let created = store.createSpace(name: "Project", sharingProfile: profile, tint: .forest)
    #expect(created)
    #expect(store.session.selectedSpace.profileID == profile)
    let id = store.session.selectedSpaceID
    let updated = store.updateSpace(id, name: "Renamed", tint: .rose)
    #expect(updated)
    #expect(store.session.selectedSpace.name == "Renamed")
    #expect(store.session.selectedSpace.profileID == profile)
    #expect(try file.load() == store.session)
  }

  @Test func launcherCreatesTabInActiveSpaceAndPersistsIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    store.cycleSpace(by: 1)
    let profile = store.session.selectedSpace.profileID
    store.showCommand()
    store.commandQuery = "example.com"
    store.acceptCommand()
    #expect(!store.commandIsOpen)
    #expect(store.session.selectedSpace.profileID == profile)
    #expect(store.session.selectedSpace.selectedTab?.url.host() == "example.com")
    #expect(store.session.spaces[0].tabs.isEmpty)
    #expect(try file.load() == store.session)
  }

  @Test func damagedSessionIsPreservedWhenUserChangesTemporarySession() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let original = Data("{damaged".utf8)
    try original.write(to: file.url)
    let store = BrowserStore(sessionFile: file)
    #expect(store.storageNotice != nil)
    store.perform(.open(URL(string: "https://example.com")!))
    store.cycleSpace(by: 1)
    #expect(try Data(contentsOf: file.url) == original)
  }
}
