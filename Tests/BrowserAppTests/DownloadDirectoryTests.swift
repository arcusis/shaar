// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor
private final class DownloadDirectoryFailureSwitch {
  var enabled = true
}

@MainActor
private final class PendingDownloadDirectoryRuntime: ARCShaarRuntime {
  var completion: (@MainActor @Sendable (URL?, (any Error)?) -> Void)?

  override func configureDownloadDirectory(
    _ directory: URL?, profileID: String,
    completion: @escaping @MainActor @Sendable (URL?, (any Error)?) -> Void
  ) {
    self.completion = completion
  }
}

private actor DownloadDirectoryCompletionSignal {
  private(set) var cancelled = false
  func finish(cancelled: Bool) { self.cancelled = cancelled }
}

@Suite @MainActor
struct DownloadDirectoryTests {
  @Test func defaultBackendDoesNotOfferFolderSelection() throws {
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let state = BrowserSettingsState(
      workspace: workspace, preferences: BrowserPreferencesStore())
    #expect(state.profiles.allSatisfy { !$0.canChooseDownloadDirectory })
  }

  @Test func persistsOnlyTheShaarAcknowledgedFolderForOneProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let selected = root.appending(path: "Selected", directoryHint: .isDirectory)
    let acknowledged = root.appending(path: "Effective", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: acknowledged, withIntermediateDirectories: true)
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let other = try #require(workspace.workspace.catalog.profiles.last?.id)
    let preferences = BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json"))
    var applied: [(UUID, URL?)] = []
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { id, url in
        applied.append((id, url))
        return acknowledged
      })
    #expect(state.profiles.first?.canChooseDownloadDirectory == true)
    #expect(await state.applyDownloadDirectory(selected, for: profile))
    #expect(applied.count == 1 && applied[0].0 == profile && applied[0].1 == selected)
    #expect(preferences.downloadDirectory(for: profile) == acknowledged)
    #expect(preferences.downloadDirectory(for: other) == nil)
    #expect(
      BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json"))
        .downloadDirectory(for: profile) == acknowledged)
  }

  @Test func olderDirectoryAcknowledgementCannotReplaceNewerChoice() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let olderDirectory = root.appending(path: "Older", directoryHint: .isDirectory)
    let newerDirectory = root.appending(path: "Newer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: olderDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newerDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let preferences = BrowserPreferencesStore()
    var acknowledgements: [CheckedContinuation<URL?, Never>] = []
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { _, _ in
        await withCheckedContinuation { acknowledgements.append($0) }
      })

    let olderUpdate = Task { await state.applyDownloadDirectory(olderDirectory, for: profile) }
    for _ in 0..<100 where acknowledgements.count < 1 { await Task.yield() }
    try #require(acknowledgements.count == 1)
    let newerUpdate = Task { await state.applyDownloadDirectory(newerDirectory, for: profile) }
    for _ in 0..<100 where acknowledgements.count < 2 { await Task.yield() }
    try #require(acknowledgements.count == 2)

    acknowledgements[1].resume(returning: newerDirectory)
    #expect(await newerUpdate.value)
    acknowledgements[0].resume(returning: olderDirectory)
    #expect(await !olderUpdate.value)
    #expect(preferences.downloadDirectory(for: profile) == newerDirectory)
  }

  @Test func failedEngineUpdateShowsErrorUntilSuccessfulRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let preferences = BrowserPreferencesStore()
    let failure = DownloadDirectoryFailureSwitch()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { _, _ in
        if failure.enabled { throw CocoaError(.featureUnsupported) }
        return root
      })
    #expect(await state.applyDownloadDirectory(root, for: profile) == false)
    #expect(preferences.downloadDirectory(for: profile) == nil)
    #expect(
      state.downloadDirectoryErrors[profile]
        == SettingsL10n.string("The download folder could not be changed. Try again."))
    failure.enabled = false
    #expect(await state.applyDownloadDirectory(root, for: profile))
    #expect(state.downloadDirectoryErrors[profile] == nil)
    #expect(preferences.downloadDirectory(for: profile)?.path == root.path)
  }

  @Test func cancelledDirectoryUpdateDoesNotStartOrShowError() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    var applied = false
    let state = BrowserSettingsState(
      workspace: workspace, preferences: BrowserPreferencesStore(),
      downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { _, _ in
        try Task.checkCancellation()
        applied = true
        return root
      })

    let update = Task { await state.applyDownloadDirectory(root, for: profile) }
    update.cancel()

    #expect(await !update.value)
    #expect(!applied)
    #expect(state.downloadDirectoryErrors[profile] == nil)
  }

  @Test func missingEngineAcknowledgementShowsError() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let preferences = BrowserPreferencesStore()
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { _, _ in nil })
    #expect(await state.applyDownloadDirectory(root, for: profile) == false)
    #expect(preferences.downloadDirectory(for: profile) == nil)
    #expect(
      state.downloadDirectoryErrors[profile]
        == SettingsL10n.string("The download folder could not be changed. Try again."))
  }

  @Test func deletedProfileDoesNotReceiveLateDirectoryAcknowledgement() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let destination = try #require(workspace.workspace.catalog.profiles.last?.id)
    let preferences = BrowserPreferencesStore()
    var acknowledgement: CheckedContinuation<URL?, Never>?
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { _, _ in
        await withCheckedContinuation { acknowledgement = $0 }
      })

    let update = Task { await state.applyDownloadDirectory(root, for: profile) }
    for _ in 0..<100 where acknowledgement == nil { await Task.yield() }
    try #require(acknowledgement != nil)
    try workspace.deleteProfile(profile, movingSpacesTo: destination)
    acknowledgement?.resume(returning: root)

    #expect(await !update.value)
    #expect(preferences.downloadDirectory(for: profile) == nil)
  }

  @Test func resetUsesEngineAcknowledgementAndClearsSavedOverride() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let profile = try #require(workspace.workspace.catalog.profiles.first?.id)
    let preferences = BrowserPreferencesStore()
    preferences.setDownloadDirectory(root, for: profile)
    var appliedProfile: UUID?
    let state = BrowserSettingsState(
      workspace: workspace, preferences: preferences, downloadDirectorySettingsEnabled: true,
      applyDownloadDirectory: { id, directory in
        appliedProfile = id
        #expect(directory == nil)
        return root
      })
    #expect(await state.applyDownloadDirectory(nil, for: profile))
    #expect(appliedProfile == profile)
    #expect(preferences.downloadDirectory(for: profile) == nil)
  }

  @Test func rejectsMissingAndApplicationBundleFolders() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let bundle = root.appending(path: "Browser.app", directoryHint: .isDirectory)
    let valid = root.appending(path: "Downloads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(DownloadDirectoryPolicy.validate(valid, bundleURL: bundle))
    #expect(!DownloadDirectoryPolicy.validate(bundle, bundleURL: bundle))
    #expect(!DownloadDirectoryPolicy.validate(bundle.appending(path: "Nested"), bundleURL: bundle))
    #expect(!DownloadDirectoryPolicy.validate(root.appending(path: "Missing"), bundleURL: bundle))
  }

  @Test func unavailableShaarProfileDoesNotAcknowledgeDirectoryChange() async {
    let apply = NativeBrowserHost.makeDownloadDirectoryApplier(runtime: ARCShaarRuntime())
    await #expect(throws: (any Error).self) {
      _ = try await apply(UUID(), URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func cancellingNativeDirectoryAcknowledgementDoesNotWaitForRuntimeReply() async throws {
    let runtime = PendingDownloadDirectoryRuntime()
    let apply = NativeBrowserHost.makeDownloadDirectoryApplier(runtime: runtime)
    let signal = DownloadDirectoryCompletionSignal()
    let task = Task {
      do {
        _ = try await apply(UUID(), URL(fileURLWithPath: "/tmp"))
        await signal.finish(cancelled: false)
      } catch is CancellationError {
        await signal.finish(cancelled: true)
      } catch {
        await signal.finish(cancelled: false)
      }
    }
    for _ in 0..<100 where runtime.completion == nil { await Task.yield() }
    try #require(runtime.completion != nil)
    task.cancel()
    try await Task.sleep(for: .milliseconds(50))
    let cancelledBeforeReply = await signal.cancelled
    runtime.completion?(URL(fileURLWithPath: "/tmp"), nil)
    await task.value

    #expect(cancelledBeforeReply)
  }
}
