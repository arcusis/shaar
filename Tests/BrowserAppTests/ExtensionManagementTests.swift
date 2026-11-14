// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

struct ExtensionManagementTests {
  private let validID = String(repeating: "b", count: 32)

  @Test @MainActor func enableSwitchNameIdentifiesTheExtension() {
    for enabled in [true, false] {
      let item = ManagedExtension(
        id: validID, name: "Password Manager", version: "1", description: "",
        enabled: enabled, mayDisable: true, permissions: [], hostPermissions: [])
      #expect(ExtensionRow.toggleAccessibilityLabel(for: item) == "Password Manager")
    }
  }

  @Test @MainActor func manageOperationRepliesReturnToTheMainActor() async {
    let reply: Bool = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        ExtensionManageDelivery.deliver("ok") { value in
          continuation.resume(returning: Thread.isMainThread && value == "ok")
        }
      }
    }
    #expect(reply)
  }

  @Test @MainActor func rowCallbacksAreSendableForSwiftUIBindings() {
    var enabled = false
    let actions = ExtensionRowActions(
      run: {}, setPinned: { _ in }, setEnabled: { enabled = $0 }, showDetails: {})
    requireSendable(actions.setEnabled)
    actions.setEnabled(true)
    #expect(enabled)
  }

  private func requireSendable<T: Sendable>(_ value: T) { _ = value }

  @Test func shaarListHidesComponentLocationsWithoutMatchingNames() throws {
    func row(_ id: String, name: String, source: Int) -> [String: Any] {
      ["id": id, "name": name, "version": "1.0", "source": source]
    }
    let userPDF = String(repeating: "a", count: 32)
    let component = String(repeating: "c", count: 32)
    let externalComponent = String(repeating: "d", count: 32)
    let policyExtension = String(repeating: "e", count: 32)
    let missingLocation = String(repeating: "f", count: 32)
    let reply: [String: Any] = [
      "schemaVersion": 1,
      "extensions": [
        row(component, name: "Notes", source: 5),
        row(userPDF, name: "Chromium PDF Viewer", source: 4),
        row(externalComponent, name: "External PDF", source: 10),
        row(policyExtension, name: "Policy Extension", source: 9),
        ["id": missingLocation, "name": "Unknown", "version": "1.0"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: reply)
    let json = try #require(String(data: data, encoding: .utf8))
    let rows = try #require(ARCVisibleShaarExtensionRows(json))
    #expect(rows.compactMap { $0["id"] as? String } == [userPDF, policyExtension])
  }

  @Test func shaarListRejectsBooleanExtensionLocations() throws {
    let reply: [String: Any] = [
      "schemaVersion": 1,
      "extensions": [[
        "id": String(repeating: "a", count: 32), "name": "Example",
        "version": "1.0", "source": true,
      ]],
    ]
    let data = try JSONSerialization.data(withJSONObject: reply)
    let json = try #require(String(data: data, encoding: .utf8))
    let rows = try #require(ARCVisibleShaarExtensionRows(json))
    #expect(rows.isEmpty)
  }

  @Test func popupCloseLabelNamesTheExtensionInBothLanguages() {
    let popup = ExtensionPopupContext(
      id: "popup", profileID: UUID(), tabID: UUID(), extensionID: validID, name: "Notes")
    #expect(popup.closeAccessibilityLabel(language: .english) == "Close Notes extension")
    #expect(
      popup.closeAccessibilityLabel(language: .hebrew)
        == "סגירת התוסף \u{2068}Notes\u{2069}")
  }

  @Test func extensionHelpIncludesDistinctActionTitlesAndFallsBackToItsName() {
    let item = ManagedExtension(
      id: validID, name: "Password Manager", version: "1", description: "", enabled: true,
      mayDisable: true, permissions: [], hostPermissions: [])
    #expect(item.help(actionTitle: "Unlock vault") == "Password Manager: Unlock vault")
    #expect(item.help(actionTitle: "  Unlock vault\n") == "Password Manager: Unlock vault")
    #expect(item.help(actionTitle: nil) == "Password Manager")
    #expect(item.help(actionTitle: " \n") == "Password Manager")
    #expect(item.help(actionTitle: "Password Manager") == "Password Manager")
  }

  @Test func operationsMapToBridgeOperationsWithTheirArguments() {
    let enable = ExtensionManagementOperation.setEnabled(id: validID, enabled: true)
    #expect(enable.bridgeOperation == .setEnabled)
    #expect(enable.extensionID == validID)
    #expect(enable.enabled)
    #expect(!ExtensionManagementOperation.setEnabled(id: validID, enabled: false).enabled)
    #expect(ExtensionManagementOperation.uninstall(id: validID).bridgeOperation == .uninstall)
    #expect(ExtensionManagementOperation.details(id: validID).bridgeOperation == .details)
    #expect(ExtensionManagementOperation.list.bridgeOperation == .list)
    #expect(ExtensionManagementOperation.list.extensionID == nil)
    #expect(!ExtensionManagementOperation.uninstall(id: validID).enabled)
  }

  @Test func profileIDsMustBeCanonicalUUIDs() {
    #expect(ExtensionManagementOperation.isValidProfileID(UUID().uuidString))
    #expect(!ExtensionManagementOperation.isValidProfileID("profile';alert(1)"))
    #expect(!ExtensionManagementOperation.isValidProfileID(""))
  }

  @Test func resultsSeparateErrorsFromValues() throws {
    guard case .failure(let message)? = ExtensionManagementResult(json: #"{"error":"denied"}"#)
    else {
      Issue.record("expected failure")
      return
    }
    #expect(message == "denied")
    guard case .value(let data)? = ExtensionManagementResult(json: "[]") else {
      Issue.record("expected value")
      return
    }
    #expect(try JSONDecoder().decode([ManagedExtension].self, from: data).isEmpty)
    #expect(ExtensionManagementResult(json: nil) == nil)
  }

  @Test @MainActor func iconLoaderUsesTheLargestManifestIconInsideTheExtension() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "\(validID)/2.1_0")
    try FileManager.default.createDirectory(
      at: folder.appending(path: "icons"), withIntermediateDirectories: true)
    try png(size: 128).write(to: folder.appending(path: "icons/large.png"))
    try png(size: 16).write(to: folder.appending(path: "small.png"))
    try Data(#"{"icons":{"16":"small.png","128":"icons/large.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))

    let icon = ExtensionIconLoader.icon(for: validID, version: "2.1", in: root)
    #expect(icon?.representations.first?.pixelsWide == 128)
    #expect(ExtensionIconLoader.icon(for: validID, version: "9.9", in: root) == nil)

    try Data(#"{"icons":{"128":"../../escape.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))
    try png(size: 32).write(to: root.appending(path: "escape.png"))
    #expect(ExtensionIconLoader.icon(for: validID, version: "2.1", in: root) == nil)
  }

  @Test @MainActor func iconLoaderRejectsSymlinkedInstalledManifest() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "\(validID)/2.1_0")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try png(size: 16).write(to: folder.appending(path: "icon.png"))
    let externalManifest = root.appending(path: "external-manifest.json")
    try Data(#"{"icons":{"16":"icon.png"}}"#.utf8).write(to: externalManifest)
    try FileManager.default.createSymbolicLink(
      at: folder.appending(path: "manifest.json"), withDestinationURL: externalManifest)

    #expect(ExtensionIconLoader.icon(for: validID, version: "2.1", in: root) == nil)
  }

  @Test func unpackedFolderRequiresAManifestV3Directory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(ExtensionUnpackedFolder.directory(root) == nil)
    try Data(#"{"manifest_version":2,"name":"Old"}"#.utf8).write(
      to: root.appending(path: "manifest.json"))
    #expect(ExtensionUnpackedFolder.directory(root) == nil)
    try Data(#"{"manifest_version":3,"name":"Probe"}"#.utf8).write(
      to: root.appending(path: "manifest.json"))
    #expect(ExtensionUnpackedFolder.directory(root) == root.standardizedFileURL.path)
    #expect(ExtensionUnpackedFolder.directory(URL(string: "https://example.com")!) == nil)
  }

  @Test func manageReplyMapsEngineRefusalsAndPromptedInstalls() throws {
    #expect(ExtensionManageReply(json: nil, code: 1) == .failed)
    #expect(
      ExtensionManageReply(json: nil, code: 1, action: "setDeveloperMode") == .unsupported)
    #expect(ExtensionManageReply(json: nil, code: 1, action: "loadUnpacked") == .unsupported)
    #expect(ExtensionManageReply(json: nil, code: 1, action: "uninstall") == .failed)
    #expect(ExtensionManageReply(json: nil, code: 15) == .unsupported)
    #expect(
      ExtensionManageReply(json: #"{"schemaVersion":1,"prompted":true}"#, code: 0) == .prompted)
    #expect(ExtensionManageReply(json: #"{"schemaVersion":1,"updated":true}"#, code: 0) == .updated)
    #expect(ExtensionManageReply(json: "true", code: 0) == .failed)
    #expect(
      ExtensionPageOrigin.string(from: URL(string: "https://example.com/path")!)
        == "https://example.com")
    #expect(ExtensionPageOrigin.accepts("https://example.com"))
    #expect(!ExtensionPageOrigin.accepts("https://example.com/"))
    #expect(
      ExtensionPageOrigin.string(from: URL(string: "https://example.com:443/path")!)
        == "https://example.com")
    #expect(
      ExtensionPageOrigin.string(from: URL(string: "http://example.com:80/a")!)
        == "http://example.com")
    #expect(
      ExtensionPageOrigin.string(from: URL(string: "https://example.com:8443/a")!)
        == "https://example.com:8443")
    #expect(ExtensionPageOrigin.string(from: URL(string: "https://[::1]/path")!) == "https://[::1]")
    #expect(
      ExtensionPageOrigin.string(from: URL(string: "http://[::1]:8080/")!) == "http://[::1]:8080")
    #expect(ExtensionPageOrigin.accepts("https://[::1]"))
    #expect(!ExtensionPageOrigin.accepts("https://::1"))
    #expect(!ExtensionPageOrigin.accepts("https://example.com:443"))
    #expect(
      ExtensionPageOrigin.string(from: URL(string: "https://user:pass@example.com/a?q=1#h")!)
        == "https://example.com")
    let listed = try JSONDecoder().decode(
      [ManagedExtension].self,
      from: Data(
        #"[{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"Probe","version":"1","description":"","enabled":true,"mayDisable":true,"permissions":[],"hostPermissions":[],"siteAccess":"onSite"}]"#
          .utf8))
    #expect(listed.first?.siteAccess == "onSite")
  }

  @Test @MainActor func developerModePersistsAndUnpackedLoadReportsTheEngineRefusal() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let profile = UUID()
    let store = BrowserPreferencesStore(fileURL: file)
    store.setExtensionDeveloperMode(true, for: profile)
    #expect(BrowserPreferencesStore(fileURL: file).extensionDeveloperMode(for: profile))
    store.setExtensionDeveloperMode(false, for: profile)
    #expect(!BrowserPreferencesStore(fileURL: file).extensionDeveloperMode(for: profile))

    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":3,"name":"Probe"}"#.utf8).write(
      to: folder.appending(path: "manifest.json"))
    let disabled = ExtensionManagerModel(profileID: profile, extensions: [])
    disabled.loadUnpacked(at: folder, tabID: nil)
    #expect(disabled.status == "Turn on Developer mode to load an unpacked extension.")
    let model = ExtensionManagerModel(profileID: profile, extensions: [], developerMode: true)
    model.loadUnpacked(at: folder, tabID: nil)
    #expect(model.status == ExtensionInstallNotice.needsNewerEngine)
    let invalidFolderModel = ExtensionManagerModel(
      profileID: profile, extensions: [], developerMode: true)
    let empty = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    invalidFolderModel.loadUnpacked(at: empty, tabID: nil)
    #expect(invalidFolderModel.status == "Choose a folder that contains a Manifest V3 extension.")
  }

  @Test func bridgeReportsInvalidArgumentAndAMissingEngineSeparately() {
    let runtime = ARCShaarRuntime()
    let missingEngine = CodeSink()
    runtime.submitExtensionManage(
      forProfileID: UUID().uuidString, tabID: nil,
      payload: ["schemaVersion": 1, "action": "setDeveloperMode", "enabled": true]
    ) { _, code in
      missingEngine.code = code
    }
    #expect(missingEngine.code == 3)
    #expect(ExtensionManageReply(json: nil, code: missingEngine.code ?? 0) == .failed)

    let invalid = CodeSink()
    runtime.submitExtensionManage(
      forProfileID: "not-a-profile", tabID: nil, payload: ["schemaVersion": 1]
    ) { _, code in
      invalid.code = code
    }
    #expect(invalid.code == 1)
    #expect(ExtensionManageReply(json: nil, code: invalid.code ?? 0) == .failed)
  }

  @Test @MainActor func manageRepliesReportDeveloperModeAndInstallRefusals() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"manifest_version":3,"name":"Probe"}"#.utf8).write(
      to: folder.appending(path: "manifest.json"))
    func preferences() -> BrowserPreferencesStore {
      BrowserPreferencesStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json"))
    }
    let togglePreferences = preferences()
    let toggleRuntime = ScriptedManageRuntime(replies: [(nil, 1)])
    let toggle = ExtensionManagerModel.shared(
      runtime: toggleRuntime, preferences: togglePreferences, profileID: UUID())
    toggle.setDeveloperMode(true)
    await Task.yield()
    #expect(!toggle.developerMode)
    #expect(!togglePreferences.extensionDeveloperMode(for: toggle.profileID))
    #expect(toggle.status == ExtensionInstallNotice.needsNewerEngine)
    #expect(toggleRuntime.actions == ["setDeveloperMode"])

    let loadPreferences = preferences()
    let loadProfile = UUID()
    loadPreferences.setExtensionDeveloperMode(true, for: loadProfile)
    let loadRuntime = ScriptedManageRuntime(
      replies: [
        (#"{"schemaVersion":1,"updated":true}"#, 0),
        (#"{"schemaVersion":1,"updated":true}"#, 0), (nil, 1),
      ])
    let load = ExtensionManagerModel.shared(
      runtime: loadRuntime, preferences: loadPreferences, profileID: loadProfile)
    load.loadUnpacked(at: folder, tabID: nil)
    await Task.yield()
    #expect(load.developerMode)
    #expect(loadPreferences.extensionDeveloperMode(for: loadProfile))
    #expect(load.status == ExtensionInstallNotice.needsNewerEngine)
    #expect(loadRuntime.actions == ["setDeveloperMode", "setDeveloperMode", "loadUnpacked"])

    let failedPreferences = preferences()
    let failedProfile = UUID()
    failedPreferences.setExtensionDeveloperMode(true, for: failedProfile)
    let failedRuntime = ScriptedManageRuntime(
      replies: [
        (#"{"schemaVersion":1,"updated":true}"#, 0),
        (#"{"schemaVersion":1,"updated":true}"#, 0), (nil, 2),
      ])
    let failed = ExtensionManagerModel.shared(
      runtime: failedRuntime, preferences: failedPreferences, profileID: failedProfile)
    failed.loadUnpacked(at: folder, tabID: nil)
    await Task.yield()
    #expect(failed.status == ExtensionInstallNotice.installFailed)
    #expect(failedRuntime.actions == ["setDeveloperMode", "setDeveloperMode", "loadUnpacked"])

    let privateAccess = ScriptedManageRuntime(replies: [(nil, 15)])
    let extensions = ExtensionManagerModel.shared(
      runtime: privateAccess, preferences: preferences(), profileID: UUID())
    extensions.setIncognitoEnabled(validID, enabled: true)
    #expect(extensions.status == ExtensionInstallNotice.privateAccessRefused)
    #expect(privateAccess.actions == ["setIncognitoEnabled"])
    let listed = try JSONDecoder().decode(
      ManagedExtension.self,
      from: Data(
        #"{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"Probe","version":"1","description":"","enabled":true,"mayDisable":true,"permissions":[],"hostPermissions":[]}"#
          .utf8))
    #expect(listed.incognitoEnabled != true)
  }

  @Test @MainActor func staleDeveloperModeFailureDoesNotReplaceNewerSuccess() throws {
    let profileID = UUID()
    let preferencesFile = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: preferencesFile) }
    let preferences = BrowserPreferencesStore(fileURL: preferencesFile)
    let runtime = DelayedDeveloperModeRuntime()
    let model = ExtensionManagerModel.shared(
      runtime: runtime, preferences: preferences, profileID: profileID)

    model.setDeveloperMode(true)
    model.setDeveloperMode(false)
    #expect(runtime.replies.count == 2)

    runtime.complete(1, json: #"{"schemaVersion":1,"updated":true}"#, code: 0)
    runtime.complete(0, json: nil, code: 1)

    #expect(!model.developerMode)
    #expect(model.status == nil)
    #expect(!preferences.extensionDeveloperMode(for: profileID))
  }

  @Test @MainActor func siteAccessOriginFollowsTheKeyWindowThenTheFocusedWindow() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: root.appending(path: "workspace.json"),
        legacySessionURL: root.appending(path: "session.json")))
    let firstID = try #require(workspace.workspace.windows.first?.id)
    let secondID = try workspace.newWindow(from: firstID)
    let first = try #require(workspace.stores[firstID])
    let second = try #require(workspace.stores[secondID])
    first.perform(.open(URL(string: "https://example.com/path")!))
    second.perform(.open(URL(string: "https://other.example:443/page")!))
    let profile = first.session.selectedSpace.profileID
    let runtime = WindowMapRuntime()
    let firstWindow = orderedOutWindow()
    let secondWindow = orderedOutWindow()
    runtime.windows[firstID.uuidString] = firstWindow
    runtime.windows[secondID.uuidString] = secondWindow
    let state = BrowserSettingsState(
      workspace: workspace,
      preferences: BrowserPreferencesStore(fileURL: root.appending(path: "preferences.json")),
      runtime: runtime)

    #expect(state.browserStoreForSiteAccess(profileID: profile, keyWindow: secondWindow) === second)
    #expect(
      ExtensionPageOrigin.string(from: try #require(second.session.selectedPage?.tab.url))
        == "https://other.example")
    let focused = try #require(workspace.workspace.focusedWindowID)
    #expect(
      state.browserStoreForSiteAccess(profileID: profile, keyWindow: nil)
        === workspace.stores[focused])
    #expect(state.browserStoreForSiteAccess(profileID: UUID(), keyWindow: nil) == nil)
    #expect(state.browserStoreForSiteAccess(profileID: UUID(), keyWindow: firstWindow) == nil)
  }

  @MainActor private func orderedOutWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 20, height: 20),
      styleMask: [.borderless], backing: .buffered, defer: true)
    window.orderOut(nil)
    return window
  }

  @Test @MainActor func pinnedExtensionsPersistPerProfile() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let work = UUID()
    let personal = UUID()
    let store = BrowserPreferencesStore(fileURL: file)
    store.setExtension(validID, pinned: true, for: work)
    store.setExtension(String(repeating: "c", count: 32), pinned: true, for: work)
    store.setExtension(validID, pinned: false, for: work)

    let reloaded = BrowserPreferencesStore(fileURL: file)
    #expect(reloaded.pinnedExtensionIDs(for: work) == [String(repeating: "c", count: 32)])
    #expect(reloaded.pinnedExtensionIDs(for: personal).isEmpty)
  }

  private func png(size: Int) throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }
}

private final class CodeSink: @unchecked Sendable {
  var code: Int?
}

private final class ScriptedManageRuntime: ARCShaarRuntime {
  var replies: [(String?, Int)]
  var actions: [String] = []

  init(replies: [(String?, Int)]) {
    self.replies = replies
    super.init()
  }

  override func submitExtensionManage(
    forProfileID profileID: String, tabID: String?, payload: [String: Any],
    completion: @escaping (String?, Int) -> Void
  ) {
    actions.append(payload["action"] as? String ?? "")
    let reply = replies.isEmpty ? (nil, 1) : replies.removeFirst()
    completion(reply.0, reply.1)
  }
}

private final class DelayedDeveloperModeRuntime: ARCShaarRuntime {
  var replies: [(String?, Int) -> Void] = []

  override func submitExtensionManage(
    forProfileID profileID: String, tabID: String?, payload: [String: Any],
    completion: @escaping (String?, Int) -> Void
  ) {
    replies.append(completion)
  }

  func complete(_ index: Int, json: String?, code: Int) {
    replies[index](json, code)
  }
}

private final class WindowMapRuntime: ARCChromiumRuntime {
  var windows: [String: NSWindow] = [:]
  override func window(forID windowID: String) -> NSWindow? { windows[windowID] }
}

extension ExtensionManagementTests {
  @Test @MainActor func iconLoaderFallsBackToTheToolbarActionIcon() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "\(validID)/1.0_0")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try png(size: 48).write(to: folder.appending(path: "action.png"))

    try Data(#"{"action":{"default_icon":"action.png"}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))
    #expect(ExtensionIconLoader.icon(for: validID, version: "1.0", in: root) != nil)

    try Data(#"{"browser_action":{"default_icon":{"19":"missing.png","48":"action.png"}}}"#.utf8)
      .write(to: folder.appending(path: "manifest.json"))
    #expect(
      ExtensionIconLoader.icon(for: validID, version: "1.0", in: root)?.representations.first?
        .pixelsWide == 48)

    try Data(#"{"name":"No icons"}"#.utf8).write(to: folder.appending(path: "manifest.json"))
    #expect(ExtensionIconLoader.icon(for: validID, version: "1.0", in: root) == nil)
    #expect(ExtensionIconLoader.icon(for: "../\(validID)", version: "1.0", in: root) == nil)
  }

  @Test func consentListsSiteAccessAndFlagsIncompletePermissions() {
    #expect(
      ExtensionConsentPermissions.displayValues(
        permissions: ["storage"], hostPermissions: ["https://example.com/*"], complete: true)
        == ["storage", "Site access: https://example.com/*"])
    #expect(
      ExtensionConsentPermissions.displayValues(
        permissions: ["tabs"], hostPermissions: nil, complete: true)
        == ["tabs", ExtensionConsentPermissions.unknownAccess])
    #expect(
      ExtensionConsentPermissions.displayValues(
        permissions: [], hostPermissions: [], complete: false)
        == [ExtensionConsentPermissions.unknownAccess])
  }

  @Test @MainActor func previewManagerListsEnabledPinsAndKeepsThemReadOnly() {
    let profile = UUID()
    let enabled = managed(id: String(repeating: "c", count: 32), enabled: true)
    let disabled = managed(id: String(repeating: "d", count: 32), enabled: false)
    let model = ExtensionManagerModel(
      profileID: profile, extensions: [enabled, disabled],
      pinnedIDs: [disabled.id, enabled.id, String(repeating: "e", count: 32)])
    #expect(model.pinnedExtensions == [enabled])
    model.setPinned(enabled.id, pinned: false)
    #expect(model.pinnedIDs.contains(enabled.id))
  }

  @Test @MainActor func managedExtensionNamesFollowTheSelectedLanguageOrder() {
    let english = ManagedExtension(
      id: String(repeating: "a", count: 32), name: "A", version: "1", description: "",
      enabled: true, mayDisable: true, permissions: [], hostPermissions: [])
    let hebrew = ManagedExtension(
      id: String(repeating: "b", count: 32), name: "אב", version: "1", description: "",
      enabled: true, mayDisable: true, permissions: [], hostPermissions: [])
    #expect(
      ExtensionManagerModel.sortedExtensions([english, hebrew], language: .hebrew).map(\.id)
        == [hebrew.id, english.id])
    #expect(
      ExtensionManagerModel.sortedExtensions([english, hebrew], language: .english).map(\.id)
        == [english.id, hebrew.id])
  }

  private func managed(id: String, enabled: Bool) -> ManagedExtension {
    ManagedExtension(
      id: id, name: "Extension \(id.prefix(1))", version: "1.0", description: "",
      enabled: enabled, mayDisable: true, permissions: [], hostPermissions: [])
  }
}
