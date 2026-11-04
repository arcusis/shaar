import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadDirectoryTests {
  @Test func appliesTheProfileDirectoryBeforePersistingTheEngineAcknowledgement() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let preferences = BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json"))
    let selected = root.appending(path: "Downloads", directoryHint: .isDirectory)
    let acknowledged = root.appending(path: "Engine Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: acknowledged, withIntermediateDirectories: true)

    var appliedProfile: UUID?
    var appliedDirectory: URL?
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { id, directory in
        appliedProfile = id
        appliedDirectory = directory
        return acknowledged
      })

    #expect(await state.applyDownloadDirectory(selected, for: profile))
    #expect(appliedProfile == profile)
    #expect(appliedDirectory == selected)
    #expect(preferences.downloadDirectory(for: profile) == acknowledged)
    #expect(
      BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json"))
        .downloadDirectory(for: profile) == acknowledged)
  }

  @Test func validatesExistingWritableDirectoryOutsideTheApplicationBundle() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let bundle = root.appending(path: "App.app", directoryHint: .isDirectory)
    let valid = root.appending(path: "Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(DownloadDirectoryPolicy.validate(valid, bundleURL: bundle))
    #expect(!DownloadDirectoryPolicy.validate(bundle, bundleURL: bundle))
    #expect(!DownloadDirectoryPolicy.validate(bundle.appending(path: "Nested"), bundleURL: bundle))
    #expect(!DownloadDirectoryPolicy.validate(root.appending(path: "Missing"), bundleURL: bundle))
  }

  @Test func downloadFolderBookmarkPersistsPerProfile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "preferences.json")
    let profile = UUID()
    let selected = root.appending(path: "Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)

    let preferences = BrowserPreferencesStore(fileURL: file)
    preferences.setDownloadDirectory(selected, for: profile)
    let restored = BrowserPreferencesStore(fileURL: file)

    #expect(restored.downloadDirectory(for: profile)?.standardizedFileURL == selected.standardizedFileURL)
    #expect(restored.downloadDirectory(for: UUID()) == nil)
  }
}
