// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Exercises the production backend selector and browser host without showing a window.
@MainActor
final class ShaarFirstTabProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let tabID: UUID
  private let profileID: UUID
  private let checksCoreRoutes: Bool
  private let checksExtensions: Bool
  private let checksPrivatePrivacy: Bool
  private let output: URL
  private let dataRoot: URL
  private let pageURL = URL(string: "https://example.com")!
  private var finished = false
  private var passed = false
  private var navigationCommitted = false
  private var coreChecksStarted = false
  private var coreRoutesObserved = false
  private var extensionListObserved = false
  private var privatePolicyStatus: [AnyHashable: Any] = [:]
  private var privatePolicyChecks: [String: Bool] = [:]

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }

    let framework = URL(filePath: try value(after: "--probe-framework"))
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    checksCoreRoutes = arguments.contains("--probe-shaar-core-routes")
    checksExtensions = arguments.contains("--probe-shaar-extensions")
    checksPrivatePrivacy = arguments.contains("--probe-shaar-private-privacy")
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    store.perform(.open(pageURL))
    guard let id = store.session.selectedSpace.selectedTabID else {
      throw Failure("The fresh workspace did not create its first tab.")
    }
    tabID = id
    guard let owner = store.session.profileID(forTabID: id) else {
      throw Failure("The first tab has no profile.")
    }
    profileID = owner
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let probe = try ShaarFirstTabProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(Data("Shaar first-tab probe: \(error)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    let previousCommitted = runtime.onDocumentCommitted
    runtime.onDocumentCommitted = { [weak self] id, profile in
      previousCommitted?(id, profile)
      guard let self, id == self.tabID.uuidString else { return }
      self.navigationCommitted = true
      DispatchQueue.main.async { [weak self] in self?.checkTab() }
    }
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
        self.checkTab()
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      self?.finish(error: "Timed out waiting for a native Shaar tab.")
    }
    let result = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func checkTab() {
    guard !finished else { return }
    let tab = tabID.uuidString
    if let view = runtime.view(forTabID: tab),
      let windowID = runtime.windowID(forTabID: tab),
      let window = runtime.window(forID: windowID),
      host.contexts.values.contains(where: { $0.engine.pages[tabID] != nil }),
      workspace.stores.values.contains(where: {
        Self.matchesRequestedURL($0.session.selectedSpace.selectedTab?.url, requested: pageURL)
      }),
      navigationCommitted,
      !window.isVisible, NSApp.windows.allSatisfy({ !$0.isVisible })
    {
      if checksExtensions {
        checkExtensionRoute(tabID: tab, nativeView: view)
      } else if checksCoreRoutes {
        checkCoreRoutes(tabID: tab, nativeView: view)
      } else if checksPrivatePrivacy {
        checkPrivatePrivacy(tabID: tab, nativeView: view)
      } else {
        finish(tabID: tab, nativeView: view)
      }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.checkTab()
    }
  }

  private func checkPrivatePrivacy(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    let contextID = UUID().uuidString
    runtime.createPrivateContextID(contextID, sourceProfileID: profileID.uuidString) {
      [weak self] opened, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard opened, error == nil else {
          self.finish(
            error: "Shaar private context could not be created: \(String(describing: error)).")
          return
        }
        self.privatePolicyStatus = await self.runtime.privatePrivacyStatus(forContextID: contextID)
        self.privatePolicyChecks = PrivatePrivacyEvidence.engineStatus(self.privatePolicyStatus)
        let released = self.runtime.releasePrivateContextID(contextID)
        let failed = self.privatePolicyChecks.filter { !$0.value }.keys.sorted()
        guard released, failed.isEmpty else {
          self.finish(error: "Shaar private policies failed: \(failed.joined(separator: ", ")).")
          return
        }
        self.finish(tabID: tabID, nativeView: nativeView)
      }
    }
  }

  private func checkExtensionRoute(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    let owner = profileID.uuidString
    guard runtime.extensionsDirectory(forProfileID: owner) != nil else {
      finish(error: "Shaar did not provide the profile extension directory.")
      return
    }
    runtime.manageExtensions(
      forProfileID: owner, operation: .list, extensionID: nil, enabled: false
    ) { [weak self] json in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let json, let data = json.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          Set(rows.compactMap { $0["id"] as? String }).count == rows.count
        else {
          self.finish(error: "Shaar extension list failed for the owning profile.")
          return
        }
        self.extensionListObserved = true
        self.finish(tabID: tabID, nativeView: nativeView)
      }
    }
  }

  private func checkCoreRoutes(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    let owner = profileID.uuidString
    runtime.bookmarks(forProfileID: owner) { [weak self] tree, error in
      guard let self else { return }
      guard error == nil, tree?["bar"] != nil, tree?["other"] != nil else {
        self.finish(error: "Shaar bookmarks tree failed: \(String(describing: error))")
        return
      }
      self.runtime.history(forProfileID: owner, limit: 20) { [weak self] rows, error in
        guard let self else { return }
        guard error == nil, rows != nil else {
          self.finish(error: "Shaar history query failed: \(String(describing: error))")
          return
        }
        let token = UUID().uuidString
        guard
          self.runtime.find(
            inTabID: tabID, profileID: owner, requestID: token, text: "Example", forward: true)
        else {
          self.finish(error: "Shaar find request was rejected.")
          return
        }
        self.runtime.stopFinding(inTabID: tabID)
        self.coreRoutesObserved = true
        DispatchQueue.main.async { [weak self] in
          self?.finish(tabID: tabID, nativeView: nativeView)
        }
      }
    }
  }

  static func matchesRequestedURL(_ actual: URL?, requested: URL) -> Bool {
    guard let actual, actual.scheme == requested.scheme, actual.host == requested.host,
      actual.query == requested.query, actual.fragment == requested.fragment
    else { return false }
    return actual.path == requested.path || (actual.path == "/" && requested.path.isEmpty)
  }

  private func finish(tabID: String? = nil, nativeView: NSView? = nil, error: String? = nil) {
    guard !finished else { return }
    finished = true
    passed = tabID != nil && nativeView != nil && error == nil
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "shaar-first-tab",
      "backend": "shaar",
      "passed": passed,
      "tabID": tabID ?? "",
      "nativeView": nativeView != nil,
      "navigationObserved": navigationCommitted,
      "coreRoutesObserved": coreRoutesObserved,
      "extensionListObserved": extensionListObserved,
      "privatePolicyStatus": privatePolicyStatus,
      "privatePolicyChecks": privatePolicyChecks,
      "requestedURL": pageURL.absoluteString,
      "allWindowsHidden": NSApp.windows.allSatisfy { !$0.isVisible },
      "error": error ?? "",
    ]
    do {
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      passed = false
      FileHandle.standardError.write(Data("Shaar first-tab report failed: \(error)\n".utf8))
    }
    if passed {
      for context in host.contexts.values { _ = runtime.closeWindowID(context.nativeID) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.runtime.quit()
      }
    } else {
      runtime.quit()
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
