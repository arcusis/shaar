import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreTests {
  @Test func openingAndCancelingLauncherDoesNotCreateTabsOrPersistChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    let before = store.session
    store.showCommand()
    store.commandQuery = "example.com"
    store.dismissCommand()
    #expect(store.session == before)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
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
