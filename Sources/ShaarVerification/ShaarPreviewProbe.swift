// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Runs the preview's product host and Shaar backend without ordering any window onscreen.
@MainActor
final class ShaarPreviewProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let output: URL
  private let dataRoot: URL
  private let downloadURL: URL?
  private let firstWindowID: UUID
  private let firstTabID: UUID
  private let firstProfileID: UUID
  private let firstURL = URL(string: "https://example.com/")!
  private let nextURL = URL(string: "https://example.com/?shaar-preview=two")!
  private var privateHost: PrivateBrowserHost?
  private var committed: [String: String] = [:]
  private var latest: [String: String] = [:]
  private var downloads: [[String: Any]] = []
  private var results: [String: [String: Any]] = [:]
  private var profileTabID: UUID?
  private var visibleWindowEvidence: [String] = []
  private var finished = false
  private var passed = false

  private var firstNativeWindowID: String {
    host.contexts[firstWindowID]?.nativeID ?? ""
  }

  private init(arguments: [String]) throws {
    func value(_ flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }
    output = URL(filePath: try value("--probe-output"))
    dataRoot = URL(filePath: try value("--probe-data-dir"), directoryHint: .isDirectory)
    downloadURL = try? URL(string: value("--probe-download-url"))
    let framework = URL(filePath: try value("--probe-framework"))
    guard
      let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
        as? ARCShaarRuntime
    else { throw Failure("Backend selector did not construct Shaar runtime.") }
    runtime = selected
    workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("Fresh workspace has no window.") }
    firstWindowID = window.id
    store.perform(.open(firstURL))
    guard let tab = store.session.selectedSpace.selectedTabID,
      let profile = store.session.profileID(forTabID: tab)
    else { throw Failure("Fresh workspace did not create a tab.") }
    firstTabID = tab
    firstProfileID = profile
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let windowGuard = try HiddenWindowOrderGuard.install()
      defer { windowGuard.restore() }
      return try ShaarPreviewProbe(arguments: arguments).run()
    } catch {
      FileHandle.standardError.write(Data("Shaar preview probe: \(error)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    let previousChanged = runtime.onTabChanged
    runtime.onTabChanged = { [weak self] tab, url, title, loading, back, forward in
      previousChanged?(tab, url, title, loading, back, forward)
      self?.latest[tab] = url
    }
    let previousCommitted = runtime.onDocumentCommitted
    runtime.onDocumentCommitted = { [weak self] tab, profile in
      previousCommitted?(tab, profile)
      guard let self else { return }
      self.committed[tab] = self.latest[tab]
    }
    let previousDownload = runtime.onDownloadChanged
    runtime.onDownloadChanged = { [weak self] profile, item in
      previousDownload?(profile, item)
      if profile == self?.firstProfileID.uuidString { self?.downloads.append(item) }
    }
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
        Task { await self.exercise() }
      } catch { self.finish(error: "Host restore: \(error)") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      self?.finish(error: "Preview probe timed out.")
    }
    let exitCode = runtime.run(
      withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && exitCode == 0 ? 0 : 1
  }

  private func exercise() async {
    await check("openTab") {
      try await self.wait("first native tab") {
        self.runtime.view(forTabID: self.firstTabID.uuidString) != nil
          && self.host.contexts[self.firstWindowID]?.engine.pages[self.firstTabID] != nil
          && self.committed[self.firstTabID.uuidString] == self.firstURL.absoluteString
      }
    }
    await check("navigate") {
      guard
        self.runtime.navigateTabID(
          self.firstTabID.uuidString, profileID: self.firstProfileID.uuidString,
          windowID: self.firstNativeWindowID, url: self.nextURL.absoluteString)
      else { throw Failure("Shaar rejected navigation.") }
      try await self.wait("second committed URL") {
        self.committed[self.firstTabID.uuidString] == self.nextURL.absoluteString
      }
    }
    await check("backForward") {
      self.runtime.goBack(inTabID: self.firstTabID.uuidString)
      try await self.wait("back navigation") {
        self.committed[self.firstTabID.uuidString] == self.firstURL.absoluteString
      }
      self.runtime.goForward(inTabID: self.firstTabID.uuidString)
      try await self.wait("forward navigation") {
        self.committed[self.firstTabID.uuidString] == self.nextURL.absoluteString
      }
    }
    await check("devTools") {
      guard self.runtime.showDevTools(forTabID: self.firstTabID.uuidString) else {
        throw Failure("Shaar rejected DevTools open.")
      }
      try await self.wait("native DevTools view") {
        self.runtime.devToolsView(forTabID: self.firstTabID.uuidString) != nil
      }
      guard self.runtime.closeDevTools(forTabID: self.firstTabID.uuidString) else {
        throw Failure("Shaar rejected DevTools close.")
      }
    }
    await check("newWindow") {
      let id = try self.host.newWindow(from: self.firstWindowID)
      try await self.wait("second native window") {
        self.host.contexts[id] != nil
          && self.host.contexts[id].flatMap { self.runtime.window(forID: $0.nativeID) } != nil
      }
      guard self.host.contexts[id]?.window.isVisible == false else {
        throw Failure("Second window became visible.")
      }
    }
    await check("privateWindow") {
      let privateHost = PrivateBrowserHost(
        runtime: self.runtime, presentsWindows: false,
        keyWindow: { nil }, sourceProfileID: { self.firstProfileID.uuidString })
      self.privateHost = privateHost
      privateHost.installCallbacks()
      try privateHost.openWindow()
      try await self.wait("private native window") {
        guard let owner = privateHost.ownedWindows.first else { return false }
        return self.runtime.view(
          forPrivateTabID: owner.store.selectedTabID, windowID: owner.windowID,
          contextID: owner.contextID) != nil
      }
      guard privateHost.ownedWindows.allSatisfy({ !$0.window.isVisible }) else {
        throw Failure("Private window became visible.")
      }
    }
    await check("profilesSwitch") {
      let id = try self.workspace.createProfile(name: "Preview B")
      guard let store = self.host.contexts[self.firstWindowID]?.store,
        store.createSpace(name: "Preview B", sharingProfile: id, tint: .ocean)
      else { throw Failure("Could not create second profile Space.") }
      store.perform(.open(self.firstURL))
      guard let tab = store.session.selectedSpace.selectedTabID,
        store.session.profileID(forTabID: tab) == id
      else { throw Failure("Second profile did not own selected tab.") }
      self.profileTabID = tab
      try await self.wait("second profile native tab") {
        self.runtime.view(forTabID: tab.uuidString) != nil
          && self.committed[tab.uuidString] == self.firstURL.absoluteString
      }
    }
    await check("extensions") {
      guard
        let secondProfileID = self.profileTabID.flatMap({ tabID in
          self.host.contexts[self.firstWindowID]?.store.session.profileID(forTabID: tabID)
        })
      else { throw Failure("Second profile is unavailable for extension checks.") }
      let first = try await self.extensionList(profileID: self.firstProfileID)
      let second = try await self.extensionList(profileID: secondProfileID)
      guard
        Set(first.compactMap { $0["id"] as? String }).count == first.count,
        Set(second.compactMap { $0["id"] as? String }).count == second.count
      else {
        throw Failure("Profile extension lists contain duplicate or invalid IDs.")
      }
      guard
        let firstDirectory = self.runtime.extensionsDirectory(
          forProfileID: self.firstProfileID.uuidString),
        let secondDirectory = self.runtime.extensionsDirectory(
          forProfileID: secondProfileID.uuidString),
        firstDirectory != secondDirectory
      else { throw Failure("Extension directories are not profile scoped.") }
    }
    await check("downloads") {
      guard let url = self.downloadURL else { throw Failure("No download fixture URL.") }
      guard
        self.runtime.navigateTabID(
          self.firstTabID.uuidString, profileID: self.firstProfileID.uuidString,
          windowID: self.firstNativeWindowID, url: url.absoluteString)
      else { throw Failure("Shaar rejected download navigation.") }
      try await self.wait("native download event") { !self.downloads.isEmpty }
      try await self.wait("download in the app model") {
        self.host.contexts[self.firstWindowID]?.engine.downloads.items(
          in: self.firstProfileID
        ).isEmpty == false
      }
    }
    finish(error: nil)
  }

  private func extensionList(profileID: UUID) async throws -> [[String: Any]] {
    let json = await withCheckedContinuation { continuation in
      runtime.manageExtensions(
        forProfileID: profileID.uuidString, operation: .list,
        extensionID: nil, enabled: false
      ) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8),
      let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { throw Failure("Shaar extension list did not return an array.") }
    return rows
  }

  private func check(_ name: String, work: () async throws -> Void) async {
    do {
      try await work()
      guard auditVisibleWindows() else {
        throw Failure("A probe window became visible.")
      }
      results[name] = ["status": "pass", "detail": ""]
    } catch { results[name] = ["status": "fail", "detail": String(describing: error)] }
  }

  private func wait(_ name: String, condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Failure("Timed out waiting for \(name).")
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    if let error { results["probe"] = ["status": "fail", "detail": error] }
    if !auditVisibleWindows() {
      results["headless"] = ["status": "fail", "detail": "A probe window became visible."]
    }
    passed = !results.values.contains { $0["status"] as? String == "fail" }
    let report: [String: Any] = [
      "schemaVersion": 1, "probeMode": "shaar-preview", "backend": "shaar",
      "allWindowsHidden": NSApp.windows.allSatisfy { !$0.isVisible },
      "visibleWindowEvidence": visibleWindowEvidence,
      "passed": passed, "results": results,
      "diagnostics": [
        "firstNativeWindowID": firstNativeWindowID,
        "firstTabWindowID": runtime.windowID(forTabID: firstTabID.uuidString) ?? "",
        "profileTabWindowID": profileTabID.flatMap {
          runtime.windowID(forTabID: $0.uuidString)
        } ?? "",
        "profileNativeView": profileTabID.map {
          runtime.view(forTabID: $0.uuidString) != nil
        } ?? false,
        "profileCommitted": profileTabID.flatMap { committed[$0.uuidString] } ?? "",
        "downloadsSeen": downloads.count,
        "downloadPayloadKeys": downloads.first.map { Array($0.keys).sorted() } ?? [],
        "appDownloadCount": host.contexts[firstWindowID]?.engine.downloads.items(
          in: firstProfileID
        ).count ?? 0,
        "firstEngineNotice": host.contexts[firstWindowID]?.engine.notice ?? "",
      ] as [String: Any],
    ]
    do {
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
    } catch { passed = false }
    Task { await shutdown() }
  }

  private func shutdown() async {
    markShutdown("private close begin")
    for owner in privateHost?.ownedWindows ?? [] {
      await withCheckedContinuation { continuation in
        runtime.closePrivateTabID(
          owner.store.selectedTabID, windowID: owner.windowID, contextID: owner.contextID
        ) { _ in continuation.resume() }
      }
      markShutdown("private tab close complete")
      await withCheckedContinuation { continuation in
        runtime.closePrivateWindowID(owner.windowID, contextID: owner.contextID) { _ in
          continuation.resume()
        }
      }
    }
    markShutdown("private close complete")
    privateHost?.detach()
    let windowIDs = host.contexts.values.map(\.nativeID)
    for windowID in windowIDs { _ = runtime.closeWindowID(windowID) }
    markShutdown("regular close requested")
    for _ in 0..<100 {
      if windowIDs.allSatisfy({ runtime.window(forID: $0) == nil }) { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    markShutdown("engine quit requested")
    runtime.quit()
  }

  private func markShutdown(_ stage: String) {
    FileHandle.standardError.write(Data("Shaar preview shutdown: \(stage)\n".utf8))
  }

  private func auditVisibleWindows() -> Bool {
    let visible = NSApp.windows.filter(\.isVisible)
    for window in visible {
      visibleWindowEvidence.append(
        "\(NSStringFromClass(type(of: window))): \(window.title)")
      window.orderOut(nil)
    }
    return visible.isEmpty
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
