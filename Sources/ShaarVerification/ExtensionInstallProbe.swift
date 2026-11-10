// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation

@testable import ArcusisBrowser

/// Opens Settings from the real menu and loads an unpacked Manifest V3 folder through the
/// product model. On the current engine the load is refused. A later engine can install it.
@MainActor
final class ExtensionInstallProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let profileID: UUID
  private let output: URL
  private let dataRoot: URL
  private let fixture: URL
  private var finished = false
  private var passed = false
  private var navigationCommitted = false
  private var popupOpened = false

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }
    let framework = URL(filePath: try value(after: "--probe-framework"))
    guard let executable = Bundle.main.executableURL,
      ShaarFirstTabProbe.isBundledFramework(framework, for: executable)
    else {
      throw Failure(
        "The extension install probe requires Shaar Verification.app and its bundled Chromium framework."
      )
    }
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    guard
      try String(contentsOf: dataRoot.appending(path: ".arcusis-probe"), encoding: .utf8)
        == "arcusis-engine-probe-v1\n"
    else { throw Failure("Probe requires a marked temporary directory.") }
    fixture = dataRoot.appending(path: "unpacked-extension", directoryHint: .isDirectory)
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    store.perform(.open(URL(string: "https://example.com")!))
    guard let tab = store.session.selectedSpace.selectedTabID,
      let owner = store.session.profileID(forTabID: tab)
    else { throw Failure("The fresh workspace did not create its first tab.") }
    profileID = owner
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let probe = try ExtensionInstallProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(
        Data("Extension install probe: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    runtime.onDocumentCommitted = { [weak self] id, _ in
      guard let self, id == self.selectedTabID?.uuidString else { return }
      self.navigationCommitted = true
      DispatchQueue.main.async { [weak self] in self?.exerciseSettings() }
    }
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do { try self.host.restore() } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
      self?.finish(error: "Timed out waiting for the hidden page.")
    }
    let result = runtime.run(
      withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private var selectedTabID: UUID? {
    workspace.stores.values.first?.session.selectedPage?.tab.id
  }

  private func exerciseSettings() {
    guard !finished, navigationCommitted else { return }
    guard NSApp.windows.allSatisfy({ !$0.isVisible }) else {
      finish(error: "A window was visible before Settings opened.")
      return
    }
    guard host.sendMenuCommand(.settings), let settings = host.settingsController,
      let settingsWindow = settings.window, let content = settingsWindow.contentView
    else {
      finish(error: "The Settings menu did not open a hidden window.")
      return
    }
    content.layoutSubtreeIfNeeded()
    pump(0.3)
    var checks: [String: Bool] = [:]
    checks["settingsOpenedFromMenu"] = true
    checks["settingsWindowHidden"] = !settingsWindow.isVisible
    let beforeIDs = ControlSearch.identifiers(in: content)
    checks["profilesSectionControl"] = beforeIDs.contains("settings.section.profiles")
    settings.selectSettingsSection(.profiles)
    pump(0.4)
    content.layoutSubtreeIfNeeded()
    writePNG(content, name: "settings-extensions-before.png")
    let developerIDs = ControlSearch.identifiers(in: content)
    checks["developerModeControl"] = developerIDs.contains("settings.extensions.developerMode")
    settings.setExtensionDeveloperMode(true, for: profileID)
    pump(0.4)
    content.layoutSubtreeIfNeeded()
    let unpackedIDs = ControlSearch.identifiers(in: content)
    checks["loadUnpackedControl"] = unpackedIDs.contains("settings.extensions.loadUnpacked")
    do { try writeFixture() } catch {
      finish(error: "Could not write the unpacked fixture.", checks: checks)
      return
    }
    settings.loadUnpackedExtension(at: fixture, for: profileID)
    let status = waitForStatus(in: settings)
    acceptInstallPromptIfNeeded()
    pump(0.5)
    content.layoutSubtreeIfNeeded()
    writePNG(content, name: "settings-extensions-after.png")
    let installed = probeExtension(in: settings)
    if status == ExtensionInstallNotice.engineRefused && installed == nil {
      checks["engineRefusedUnpackedInstall"] = true
      checks["didNotPretendToInstall"] = true
    } else if let installed {
      recordInstalledExtension(installed, settings: settings, checks: &checks)
    } else {
      checks["engineRefusedUnpackedInstall"] = false
      checks["installedThroughProductPath"] = false
    }
    checks["windowsStayedHidden"] = NSApp.windows.allSatisfy { !$0.isVisible }
    let required = requiredChecks(checks)
    let failed = required.filter { checks[$0] != true }
    finish(
      error: failed.isEmpty ? nil : "Failed checks: \(failed.joined(separator: ", "))",
      checks: checks, status: settings.extensionStatus(for: profileID) ?? status,
      installedID: installed?.id, identifiers: Array(unpackedIDs).sorted())
  }

  private func requiredChecks(_ checks: [String: Bool]) -> [String] {
    var names = [
      "settingsOpenedFromMenu", "settingsWindowHidden", "profilesSectionControl",
      "developerModeControl", "loadUnpackedControl", "windowsStayedHidden",
    ]
    if checks["installedThroughProductPath"] == true {
      names += [
        "extensionListed", "extensionPinned", "toolbarPopupOpened", "siteAccessChanged",
        "extensionDisabled", "extensionRemoved",
      ]
    } else {
      names += ["engineRefusedUnpackedInstall", "didNotPretendToInstall"]
    }
    return names
  }

  private func recordInstalledExtension(
    _ item: ManagedExtension, settings: BrowserSettingsController, checks: inout [String: Bool]
  ) {
    checks["installedThroughProductPath"] = true
    checks["extensionListed"] = true
    checks["engineRefusedUnpackedInstall"] = false
    settings.pinManagedExtension(item.id, for: profileID)
    checks["extensionPinned"] = settings.pinnedExtensionIDs(for: profileID).contains(item.id)
    runtime.onExtensionPopup = { [weak self] payload in
      if payload["extensionID"] as? String == item.id { self?.popupOpened = true }
    }
    if let tab = selectedTabID?.uuidString {
      try? runtime.executeExtensionID(item.id, tabID: tab)
    }
    pump(2)
    checks["toolbarPopupOpened"] = popupOpened
    let origin = ExtensionPageOrigin.string(from: URL(string: "https://example.com")!)
    if let origin {
      settings.setExtensionSiteAccess(
        .onSite, id: item.id, origin: origin, tabID: selectedTabID, for: profileID)
      pump(1)
    }
    checks["siteAccessChanged"] =
      probeExtension(in: settings)?.siteAccess == ExtensionSiteAccess.onSite.rawValue
    settings.setExtensionEnabled(false, id: item.id, for: profileID)
    pump(1)
    checks["extensionDisabled"] = probeExtension(in: settings)?.enabled == false
    settings.removeManagedExtension(item.id, for: profileID)
    pump(1)
    checks["extensionRemoved"] = probeExtension(in: settings) == nil
  }

  private func waitForStatus(in settings: BrowserSettingsController) -> String? {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if let status = settings.extensionStatus(for: profileID) { return status }
      if probeExtension(in: settings) != nil { return nil }
      if pendingInstall() != nil { return nil }
      pump(0.1)
    }
    return settings.extensionStatus(for: profileID)
  }

  private func acceptInstallPromptIfNeeded() {
    guard let request = pendingInstall() else { return }
    for context in host.contexts.values {
      context.store.resolveInstallation(request.id, accepted: true)
    }
  }

  private func pendingInstall() -> ExtensionInstallRequest? {
    host.contexts.values.compactMap(\.store.installationRequests.first).first
  }

  private func probeExtension(in settings: BrowserSettingsController) -> ManagedExtension? {
    settings.managedExtensions(for: profileID).first { $0.name == "Shaar Probe Extension" }
  }

  private func writeFixture() throws {
    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    try Data(Self.manifest.utf8).write(to: fixture.appending(path: "manifest.json"))
    try Data(Self.popup.utf8).write(to: fixture.appending(path: "popup.html"))
  }

  private func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func writePNG(_ view: NSView, name: String) {
    guard view.bounds.width > 1, view.bounds.height > 1,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: output.deletingLastPathComponent().appending(path: name), options: .atomic)
  }

  private func finish(
    error: String?, checks: [String: Bool] = [:], status: String? = nil,
    installedID: String? = nil, identifiers: [String] = []
  ) {
    guard !finished else { return }
    finished = true
    let requiredPassed = error == nil
    passed = requiredPassed
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "extension-install",
      "passed": passed,
      "checks": checks,
      "status": status ?? "",
      "installedID": installedID ?? "",
      "navigationObserved": navigationCommitted,
      "identifiers": identifiers,
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
      FileHandle.standardError.write(Data("Extension install report failed: \(error)\n".utf8))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      for context in self.host.contexts.values {
        _ = self.runtime.closeWindowID(context.nativeID)
      }
      self.runtime.quit()
    }
  }

  private static let manifest = """
    {"manifest_version":3,"name":"Shaar Probe Extension","version":"1.0.0","action":{"default_popup":"popup.html","default_title":"Probe"}}
    """

  private static let popup = """
    <!doctype html><title>Probe popup</title><p id="probe">ready</p>
    """

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

@MainActor
private enum ControlSearch {
  static func identifiers(in root: NSView) -> Set<String> {
    var found: Set<String> = []
    var pending: [NSObject] = [root]
    var seen: Set<ObjectIdentifier> = []
    while let object = pending.popLast() {
      if !seen.insert(ObjectIdentifier(object)).inserted { continue }
      if let identifier = ControlSearch.identifier(of: object), !identifier.isEmpty {
        found.insert(identifier)
      }
      if let view = object as? NSView {
        pending.append(contentsOf: view.subviews)
        pending.append(
          contentsOf: view.accessibilityChildren()?.compactMap { $0 as? NSObject } ?? [])
      } else if let element = object as? NSAccessibilityElement {
        pending.append(
          contentsOf: element.accessibilityChildren()?.compactMap { $0 as? NSObject } ?? [])
      }
    }
    return found
  }

  private static func identifier(of object: NSObject) -> String? {
    if let view = object as? NSView { return view.accessibilityIdentifier() }
    if let element = object as? NSAccessibilityElement { return element.accessibilityIdentifier() }
    return nil
  }
}
