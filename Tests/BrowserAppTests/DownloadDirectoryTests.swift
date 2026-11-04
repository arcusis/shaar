import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadDirectoryTests {
  @Test func activeHostAdapterAppliesAndResetsProfileDirectory() async throws {
    let profile = UUID()
    let fake = DownloadDirectoryTransport()
    var requestedProfiles: [UUID] = []
    let apply = NativeBrowserHost.downloadDirectoryApplier(adapterForProfile: { requestedProfile in
      requestedProfiles.append(requestedProfile)
      return requestedProfile == profile ? ShaarDownloadsAdapter(transport: fake) : nil
    })

    let selected = URL(fileURLWithPath: "/tmp/profile-downloads", isDirectory: true)
    let acknowledged = try await apply(profile, selected)
    #expect(acknowledged?.path == "/tmp/profile-downloads")
    #expect(try await apply(profile, nil)?.path == "/tmp/default-downloads")
    #expect(requestedProfiles == [profile, profile])

    let calls = await fake.calls
    #expect(calls.map(\.action) == ["set", "useDefault"])
  }

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

    #expect(state.profiles.first?.canChooseDownloadDirectory == true)
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

    #expect(
      restored.downloadDirectory(for: profile)?.standardizedFileURL == selected.standardizedFileURL)
    #expect(restored.downloadDirectory(for: UUID()) == nil)
  }
}

private actor DownloadDirectoryTransport: ShaarDownloadsTransport {
  struct Call: Equatable {
    let action: String
  }

  private(set) var calls: [Call] = []

  func submit(operation: UInt32, arguments: Data) async throws -> Data {
    let object = try #require(JSONSerialization.jsonObject(with: arguments) as? [String: Any])
    let action = try #require(object["action"] as? String)
    calls.append(Call(action: action))
    let path = action == "set" ? object["directory"] as? String ?? "" : "/tmp/default-downloads"
    return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "directory": path])
  }
}
