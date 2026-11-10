// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import ObjectiveC

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
    guard ExtensionInstallPanelStub.install() else {
      finish(error: "The folder chooser could not be answered without a dialog.")
      return
    }
    var checks: [String: Bool] = [:]
    checks["settingsOpenedFromMenu"] = true
    checks["settingsWindowHidden"] = !settingsWindow.isVisible
    checks["profilesSectionControl"] =
      ControlSearch.button("settings.section.profiles", in: content) != nil
    guard settings.selectProfile(profileID) else {
      finish(error: "The profile row could not be selected.", checks: checks)
      return
    }
    guard ControlSearch.press("settings.section.profiles", in: content) else {
      finish(error: "The Profiles section control could not be pressed.", checks: checks)
      return
    }
    pump(0.4)
    content.layoutSubtreeIfNeeded()
    ControlSearch.reveal("settings.extensions.developerMode", in: content)
    writePNG(content, name: "settings-extensions-before.png")
    checks["developerModeControl"] =
      ControlSearch.button("settings.extensions.developerMode", in: content) != nil
    guard ControlSearch.press("settings.extensions.developerMode", in: content) else {
      finish(error: "Developer mode could not be turned on.", checks: checks)
      return
    }
    pump(0.4)
    content.layoutSubtreeIfNeeded()
    checks["loadUnpackedControl"] =
      ControlSearch.button("settings.extensions.loadUnpacked", in: content) != nil
    do { try writeFixture() } catch {
      finish(error: "Could not write the unpacked fixture.", checks: checks)
      return
    }
    ExtensionInstallPanelStub.directory = fixture
    let loaded = ControlSearch.press("settings.extensions.loadUnpacked", in: content)
    ExtensionInstallPanelStub.directory = nil
    guard loaded else {
      finish(error: "Load unpacked could not be pressed.", checks: checks)
      return
    }
    let status = waitForStatus(in: content, settings: settings)
    acceptInstallPromptIfNeeded()
    pump(0.5)
    content.layoutSubtreeIfNeeded()
    ControlSearch.reveal("settings.extensions.status", in: content)
    writePNG(content, name: "settings-extensions-after.png")
    let installed = probeExtension(in: settings)
    if status == ExtensionInstallNotice.installFailed && installed == nil {
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
    let shown = ControlSearch.identifiers(in: content).sorted()
    finish(
      error: failed.isEmpty ? nil : "Failed checks: \(failed.joined(separator: ", "))",
      checks: checks, status: status ?? "",
      installedID: installed?.id, identifiers: shown)
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
    let extensions = manager(settings)
    extensions?.setPinned(item.id, pinned: true)
    checks["extensionPinned"] = extensions?.pinnedIDs.contains(item.id) == true
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
      extensions?.setSiteAccess(
        .onSite, extensionID: item.id, origin: origin, tabID: selectedTabID)
      pump(1)
    }
    checks["siteAccessChanged"] =
      probeExtension(in: settings)?.siteAccess == ExtensionSiteAccess.onSite.rawValue
    extensions?.setEnabled(item.id, enabled: false)
    pump(1)
    checks["extensionDisabled"] = probeExtension(in: settings)?.enabled == false
    extensions?.remove(item.id)
    pump(1)
    checks["extensionRemoved"] = probeExtension(in: settings) == nil
  }

  private func manager(_ settings: BrowserSettingsController) -> ExtensionManagerModel? {
    settings.state.extensionManager(for: profileID)
  }

  private func waitForStatus(in root: NSView, settings: BrowserSettingsController) -> String? {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if let status = ControlSearch.text("settings.extensions.status", in: root) { return status }
      if probeExtension(in: settings) != nil { return nil }
      if pendingInstall() != nil { return nil }
      pump(0.1)
    }
    return ControlSearch.text("settings.extensions.status", in: root)
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
    manager(settings)?.extensions.first { $0.name == "Shaar Probe Extension" }
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
  static func reveal(_ identifier: String, in root: NSView) {
    guard let target = view(identifier: identifier, in: root),
      let scroll = target.enclosingScrollView
    else { return }
    let rect = target.convert(target.bounds, to: scroll.documentView)
    scroll.documentView?.scrollToVisible(rect.insetBy(dx: 0, dy: -80))
    root.layoutSubtreeIfNeeded()
  }

  static func press(_ identifier: String, in root: NSView) -> Bool {
    guard let button = button(identifier, in: root), button.isEnabled else { return false }
    button.performClick(nil)
    return true
  }

  static func button(_ identifier: String, in root: NSView) -> NSButton? {
    view(identifier: identifier, in: root) as? NSButton
  }

  static func text(_ identifier: String, in root: NSView) -> String? {
    guard let field = view(identifier: identifier, in: root) as? NSTextField else { return nil }
    return field.stringValue.isEmpty ? nil : field.stringValue
  }

  static func identifiers(in root: NSView) -> Set<String> {
    var found: Set<String> = []
    var pending: [NSView] = [root]
    var seen: Set<ObjectIdentifier> = []
    while let view = pending.popLast() {
      if !seen.insert(ObjectIdentifier(view)).inserted { continue }
      let identifier = view.accessibilityIdentifier()
      if !identifier.isEmpty { found.insert(identifier) }
      pending.append(contentsOf: view.subviews)
    }
    return found
  }

  private static func view(identifier: String, in root: NSView) -> NSView? {
    var pending: [NSView] = [root]
    var seen: Set<ObjectIdentifier> = []
    while let view = pending.popLast() {
      if !seen.insert(ObjectIdentifier(view)).inserted { continue }
      if view.accessibilityIdentifier() == identifier { return view }
      pending.append(contentsOf: view.subviews)
    }
    return nil
  }
}

private typealias PanelRunModal = @convention(c) (AnyObject, Selector) -> Int
private typealias PanelURL = @convention(c) (AnyObject, Selector) -> Unmanaged<NSURL>?

/// Answers the product folder chooser inside this verification process. The shipping app
/// still presents `NSOpenPanel`; the probe never does.
enum ExtensionInstallPanelStub {
  nonisolated(unsafe) static var directory: URL?
  nonisolated(unsafe) private static var installed = false
  nonisolated(unsafe) fileprivate static var originalRunModal: PanelRunModal?
  nonisolated(unsafe) fileprivate static var originalURL: PanelURL?

  static func install() -> Bool {
    guard !installed else { return true }
    let runModal = replace(
      #selector(NSSavePanel.runModal), with: #selector(NSOpenPanel.shaarProbeRunModal),
      original: &originalRunModal)
    let url = replace(
      #selector(getter: NSSavePanel.url), with: #selector(NSOpenPanel.shaarProbeURL),
      original: &originalURL)
    guard runModal, url else {
      restore()
      return false
    }
    installed = true
    return true
  }

  static func restore() {
    restore(#selector(NSSavePanel.runModal), originalRunModal)
    restore(#selector(getter: NSSavePanel.url), originalURL)
    originalRunModal = nil
    originalURL = nil
    installed = false
    directory = nil
  }

  private static func replace<Implementation>(
    _ selector: Selector, with replacement: Selector, original: inout Implementation?
  ) -> Bool {
    guard original == nil,
      let inherited = class_getInstanceMethod(NSOpenPanel.self, selector),
      let added = class_getInstanceMethod(NSOpenPanel.self, replacement)
    else { return false }
    original = unsafeBitCast(method_getImplementation(inherited), to: Implementation.self)
    method_setImplementation(inherited, method_getImplementation(added))
    return true
  }

  private static func restore<Implementation>(_ selector: Selector, _ original: Implementation?) {
    guard let original, let method = class_getInstanceMethod(NSOpenPanel.self, selector) else {
      return
    }
    method_setImplementation(method, unsafeBitCast(original, to: IMP.self))
  }
}

extension NSOpenPanel {
  @objc func shaarProbeRunModal() -> NSApplication.ModalResponse {
    if ExtensionInstallPanelStub.directory != nil { return .OK }
    guard let original = ExtensionInstallPanelStub.originalRunModal else { return .cancel }
    return NSApplication.ModalResponse(rawValue: original(self, #selector(NSSavePanel.runModal)))
  }

  @objc func shaarProbeURL() -> URL? {
    if let directory = ExtensionInstallPanelStub.directory { return directory }
    return ExtensionInstallPanelStub.originalURL?(self, #selector(getter: NSSavePanel.url))?
      .takeUnretainedValue() as URL?
  }
}
