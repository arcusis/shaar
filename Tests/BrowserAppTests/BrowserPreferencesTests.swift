import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserPreferencesTests {
  @Test func profileEnginesAndSidebarRoundTripByStableProfileID() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "preferences.json")
    let firstProfile = UUID()
    let secondProfile = UUID()
    let sharedProfile = UUID()

    let store = BrowserPreferencesStore(fileURL: fileURL)
    #expect(store.sidebarInitiallyVisible)
    #expect(store.searchEngine(for: firstProfile) == .google)
    store.setSearchEngine(.bing, for: firstProfile)
    store.setSearchEngine(.duckDuckGo, for: secondProfile)
    store.setSearchEngine(.bing, for: sharedProfile)
    store.setSidebarInitiallyVisible(false)

    let reloaded = BrowserPreferencesStore(fileURL: fileURL)
    #expect(reloaded.searchEngine(for: firstProfile) == .bing)
    #expect(reloaded.searchEngine(for: secondProfile) == .duckDuckGo)
    #expect(reloaded.searchEngine(for: sharedProfile) == .bing)
    #expect(!reloaded.sidebarInitiallyVisible)
    #expect(reloaded.storageNotice == nil)
    let directoryPermissions =
      try FileManager.default.attributesOfItem(atPath: directory.path)[
        .posixPermissions] as? NSNumber
    let filePermissions =
      try FileManager.default.attributesOfItem(atPath: fileURL.path)[
        .posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)
    #expect(filePermissions?.intValue == 0o600)
  }

  @Test func memoryOnlyStoreNeverCreatesFile() {
    let store = BrowserPreferencesStore()
    let profileID = UUID()
    store.setSearchEngine(.bing, for: profileID)
    store.setSidebarInitiallyVisible(false)
    #expect(store.searchEngine(for: profileID) == .bing)
    #expect(!store.sidebarInitiallyVisible)
    #expect(store.storageNotice == nil)
  }

  @Test func nativeVaultPreferencesDefaultOffAndPersistStableProfileOwnership() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "preferences.json")
    let firstProfile = UUID()
    let secondProfile = UUID()
    let store = BrowserPreferencesStore(fileURL: fileURL)

    let first = store.nativeVaultPreferences(for: firstProfile)
    let second = store.nativeVaultPreferences(for: secondProfile)
    #expect(!first.isEnabled)
    #expect(first.accountID == nil)
    #expect(first.vaultID != second.vaultID)
    #expect(first.deviceID != second.deviceID)

    store.setNativeVaultEnabled(true, for: firstProfile)
    store.setNativeVaultAccountID(UUID(), for: firstProfile)
    let saved = store.nativeVaultPreferences(for: firstProfile)
    let reloaded = BrowserPreferencesStore(fileURL: fileURL)
    let restored = reloaded.nativeVaultPreferences(for: firstProfile)
    #expect(restored == saved)
    #expect(restored.isEnabled)
    #expect(restored.vaultID == first.vaultID)
    #expect(restored.deviceID == first.deviceID)

    reloaded.setNativeVaultServer(.init(region: .eu), for: firstProfile)
    let rebound = reloaded.nativeVaultPreferences(for: firstProfile)
    #expect(rebound.vaultID != first.vaultID)
    #expect(rebound.accountID == nil)
    #expect(rebound.deviceID == first.deviceID)
    #expect(try String(contentsOf: fileURL, encoding: .utf8).contains("password") == false)
  }

  @Test func versionOnePreferencesMigrateWithoutChangingExistingValues() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "preferences.json")
    let profileID = UUID()
    let old = """
      {"version":1,"sidebarInitiallyVisible":false,"profileSearchEngines":["\(profileID.uuidString)","bing"]}
      """
    try Data(old.utf8).write(to: fileURL)

    let store = BrowserPreferencesStore(fileURL: fileURL)
    #expect(!store.sidebarInitiallyVisible)
    #expect(store.searchEngine(for: profileID) == .bing)
    #expect(!store.nativeVaultPreferences(for: profileID).isEnabled)
    store.setSidebarInitiallyVisible(true)
    let reloaded = BrowserPreferencesStore(fileURL: fileURL)
    #expect(reloaded.searchEngine(for: profileID) == .bing)
    #expect(reloaded.nativeVaultPreferences(for: profileID).isEnabled == false)
  }

  @Test func malformedAndFutureFilesArePreservedAcrossMutations() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    for (name, original) in [
      ("malformed.json", Data("{broken".utf8)),
      (
        "future.json",
        Data("{\"version\":3,\"sidebarInitiallyVisible\":false,\"profileSearchEngines\":[]}".utf8)
      ),
    ] {
      let fileURL = directory.appending(path: name)
      try original.write(to: fileURL)
      let store = BrowserPreferencesStore(fileURL: fileURL)
      store.setSearchEngine(.bing, for: UUID())
      store.setSidebarInitiallyVisible(false)
      #expect(try Data(contentsOf: fileURL) == original)
      #expect(
        store.storageNotice?.contains("preserved") == true
          || store.storageNotice?.contains("invalid") == true)
      if name == "future.json" {
        #expect(store.storageNotice?.contains("unsupported version") == true)
      }
    }
  }

  @Test func failedWriteKeepsValidStateAndProvidesSafeNotice() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("not a folder".utf8).write(to: directory)
    let fileURL = directory.appending(path: "preferences.json")
    let profileID = UUID()
    let store = BrowserPreferencesStore(fileURL: fileURL)
    store.setSearchEngine(.bing, for: profileID)

    #expect(store.searchEngine(for: profileID) == .bing)
    #expect(store.storageNotice?.contains("could not be saved") == true)

    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store.setSidebarInitiallyVisible(false)
    let reloaded = BrowserPreferencesStore(fileURL: fileURL)
    #expect(reloaded.searchEngine(for: profileID) == .bing)
    #expect(!reloaded.sidebarInitiallyVisible)
    #expect(store.storageNotice == nil)
  }

  @Test func moreThan512ProfilesRemainReadableAfterSave() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "preferences.json")
    let profiles = (0..<600).map { _ in UUID() }
    let store = BrowserPreferencesStore(fileURL: file)
    for id in profiles { store.setSearchEngine(.duckDuckGo, for: id) }
    let reloaded = BrowserPreferencesStore(fileURL: file)
    #expect(reloaded.storageNotice == nil)
    #expect(profiles.allSatisfy { reloaded.searchEngine(for: $0) == .duckDuckGo })
  }
}
