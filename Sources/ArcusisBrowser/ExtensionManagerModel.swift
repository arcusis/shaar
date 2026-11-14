// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Observation

private struct ExtensionManagerKey: Hashable {
  let runtime: ObjectIdentifier
  let profileID: UUID
}

private final class WeakExtensionManager {
  weak var value: ExtensionManagerModel?

  init(_ value: ExtensionManagerModel) {
    self.value = value
  }
}

/// Shared, profile-scoped extension state for Settings and the toolbar panel.
@MainActor @Observable
final class ExtensionManagerModel {
  private static var models: [ExtensionManagerKey: WeakExtensionManager] = [:]

  let profileID: UUID
  private let runtime: ARCChromiumRuntime?
  private let preferences: BrowserPreferencesStore?
  private(set) var extensions: [ManagedExtension] = []
  private(set) var icons: [String: NSImage] = [:]
  private(set) var pinnedIDs: [String] = []
  private(set) var developerMode = false
  private(set) var status: String?
  private var requestID = UUID()
  private var developerModeRequestID = UUID()
  private var extensionAccessRequestID = UUID()

  static func shared(
    runtime: ARCChromiumRuntime, preferences: BrowserPreferencesStore, profileID: UUID
  ) -> ExtensionManagerModel {
    let key = ExtensionManagerKey(runtime: ObjectIdentifier(runtime), profileID: profileID)
    if let model = models[key]?.value {
      return model
    }
    let model = ExtensionManagerModel(
      runtime: runtime, preferences: preferences, profileID: profileID)
    models[key] = WeakExtensionManager(model)
    model.refresh()
    if model.developerMode { model.verifyStoredDeveloperMode() }
    return model
  }

  static func refreshInstalled() {
    for entry in models.values {
      entry.value?.refresh()
    }
  }

  private init(
    runtime: ARCChromiumRuntime, preferences: BrowserPreferencesStore, profileID: UUID
  ) {
    self.runtime = runtime
    self.preferences = preferences
    self.profileID = profileID
    developerMode = preferences.extensionDeveloperMode(for: profileID)
  }

  init(
    profileID: UUID, extensions: [ManagedExtension], pinnedIDs: [String] = [],
    developerMode: Bool = false
  ) {
    self.runtime = nil
    self.preferences = nil
    self.profileID = profileID
    self.extensions = extensions
    self.pinnedIDs = pinnedIDs
    self.developerMode = developerMode
  }

  static func sortedExtensions(
    _ extensions: [ManagedExtension], language: BrowserLanguage = .currentLaunchLanguage
  ) -> [ManagedExtension] {
    let locale = Locale(identifier: language.localeIdentifier)
    return extensions.sorted { lhs, rhs in
      let order = lhs.name.compare(
        rhs.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
  }

  var pinnedExtensions: [ManagedExtension] {
    pinnedIDs.compactMap { id in extensions.first { $0.id == id && $0.enabled } }
  }

  func help(for item: ManagedExtension, tabID: UUID?) -> String {
    let title = tabID.flatMap {
      runtime?.extensionActionTitle(forID: item.id, tabID: $0.uuidString)
    }
    return item.help(actionTitle: title)
  }

  func refresh() {
    guard let runtime, let preferences,
      ExtensionManagementOperation.isValidProfileID(profileID.uuidString)
    else { return }
    let request = UUID()
    requestID = request
    pinnedIDs = preferences.pinnedExtensionIDs(for: profileID)
    runtime.manageExtensions(
      forProfileID: profileID.uuidString, operation: .list, extensionID: nil, enabled: false
    ) { [weak self] json in
      Task { @MainActor [weak self] in
        guard let self, self.requestID == request,
          case .value(let data)? = ExtensionManagementResult(json: json),
          let list = try? JSONDecoder().decode([ManagedExtension].self, from: data)
        else { return }
        self.extensions = Self.sortedExtensions(list)
        self.loadIcons()
      }
    }
  }

  func setPinned(_ id: String, pinned: Bool) {
    guard let preferences else { return }
    preferences.setExtension(id, pinned: pinned, for: profileID)
    pinnedIDs = preferences.pinnedExtensionIDs(for: profileID)
  }

  func setEnabled(_ id: String, enabled: Bool) {
    mutate(.setEnabled(id: id, enabled: enabled))
  }

  func remove(_ id: String) {
    setPinned(id, pinned: false)
    mutate(.uninstall(id: id))
  }

  func setDeveloperMode(_ enabled: Bool) {
    let request = UUID()
    developerModeRequestID = request
    let previousValue = developerMode
    developerMode = enabled
    status = nil
    preferences?.setExtensionDeveloperMode(enabled, for: profileID)
    submitDeveloperMode(enabled) { [weak self] reply in
      guard let self, self.developerModeRequestID == request else { return }
      switch reply {
      case .updated:
        self.status = nil
      case .unsupported:
        self.restoreDeveloperMode(previousValue)
        self.status = ExtensionInstallNotice.needsNewerEngine
      case .prompted, .failed:
        self.restoreDeveloperMode(previousValue)
        self.status = ExtensionInstallNotice.developerModeFailed
      }
    }
  }

  private func verifyStoredDeveloperMode() {
    let request = UUID()
    developerModeRequestID = request
    submitDeveloperMode(true) { [weak self] reply in
      guard let self, self.developerModeRequestID == request else { return }
      switch reply {
      case .updated:
        self.status = nil
      case .unsupported:
        self.restoreDeveloperMode(false)
        self.status = ExtensionInstallNotice.needsNewerEngine
      case .prompted, .failed:
        self.restoreDeveloperMode(false)
        self.status = ExtensionInstallNotice.developerModeFailed
      }
    }
  }

  func loadUnpacked(at url: URL, tabID: UUID?) {
    guard developerMode else {
      status = SettingsL10n.string("Turn on Developer mode to load an unpacked extension.")
      return
    }
    guard let path = ExtensionUnpackedFolder.directory(url) else {
      status = SettingsL10n.string("Choose a folder that contains a Manifest V3 extension.")
      return
    }
    let request = UUID()
    developerModeRequestID = request
    status = nil
    var payload: [String: Any] = [
      "schemaVersion": 1, "action": "loadUnpacked", "path": path,
    ]
    if let tabID { payload["tabId"] = tabID.uuidString }
    submitManage(
      ["schemaVersion": 1, "action": "setDeveloperMode", "enabled": true], tabID: nil
    ) { [weak self] modeReply in
      guard let self, self.developerModeRequestID == request else { return }
      switch modeReply {
      case .updated:
        self.submitUnpackedLoad(payload, tabID: tabID, request: request)
      case .unsupported:
        self.restoreDeveloperMode(false)
        self.status = ExtensionInstallNotice.needsNewerEngine
      case .prompted, .failed:
        self.restoreDeveloperMode(false)
        self.status = ExtensionInstallNotice.installFailed
      }
    }
  }

  private func submitUnpackedLoad(_ payload: [String: Any], tabID: UUID?, request: UUID) {
    submitManage(payload, tabID: tabID) { [weak self] reply in
      guard let self, self.developerModeRequestID == request else { return }
      switch reply {
      case .prompted:
        self.status = nil
      case .updated:
        self.status = nil
        self.refresh()
      case .unsupported:
        self.status = ExtensionInstallNotice.needsNewerEngine
      case .failed:
        self.status = ExtensionInstallNotice.installFailed
      }
    }
  }

  private func restoreDeveloperMode(_ enabled: Bool) {
    developerMode = enabled
    preferences?.setExtensionDeveloperMode(enabled, for: profileID)
  }

  func setIncognitoEnabled(_ id: String, enabled: Bool) {
    let request = UUID()
    extensionAccessRequestID = request
    guard BrowserExtension.isValidID(id) else {
      status = ExtensionInstallNotice.privateAccessRefused
      return
    }
    status = nil
    submitManage(
      [
        "schemaVersion": 1, "action": "setIncognitoEnabled", "extensionId": id,
        "enabled": enabled,
      ], tabID: nil
    ) { [weak self] reply in
      guard let self, self.extensionAccessRequestID == request else { return }
      switch reply {
      case .updated:
        self.status = nil
        self.refresh()
      case .prompted, .unsupported, .failed:
        self.status = ExtensionInstallNotice.privateAccessRefused
      }
    }
  }

  func setSiteAccess(
    _ access: ExtensionSiteAccess, extensionID: String, origin: String, tabID: UUID?
  ) {
    let request = UUID()
    extensionAccessRequestID = request
    guard BrowserExtension.isValidID(extensionID), ExtensionPageOrigin.accepts(origin) else {
      status = ExtensionInstallNotice.siteAccessRefused
      return
    }
    status = nil
    submitManage(
      [
        "schemaVersion": 1, "action": "setSiteAccess", "extensionId": extensionID,
        "access": access.rawValue, "origin": origin,
      ], tabID: tabID
    ) { [weak self] reply in
      guard let self, self.extensionAccessRequestID == request else { return }
      switch reply {
      case .updated:
        self.status = nil
        self.refresh()
      case .prompted, .unsupported:
        self.status = ExtensionInstallNotice.siteAccessRefused
      case .failed:
        self.status = ExtensionInstallNotice.siteAccessRefused
      }
    }
  }

  fileprivate func submitDeveloperMode(
    _ enabled: Bool, completion: @escaping @MainActor (ExtensionManageReply) -> Void
  ) {
    submitManage(
      ["schemaVersion": 1, "action": "setDeveloperMode", "enabled": enabled], tabID: nil,
      completion: completion)
  }

  private func mutate(_ operation: ExtensionManagementOperation) {
    guard let runtime, ExtensionManagementOperation.isValidProfileID(profileID.uuidString) else {
      return
    }
    runtime.manageExtensions(operation, profileID: profileID) { [weak self] _ in self?.refresh() }
  }

  private func submitManage(
    _ payload: [String: Any], tabID: UUID?,
    completion: @escaping @MainActor (ExtensionManageReply) -> Void
  ) {
    guard let runtime else {
      completion(.unsupported)
      return
    }
    runtime.submitExtensionManage(
      profileID: profileID, tabID: tabID, payload: payload, completion: completion)
  }

  private func loadIcons() {
    guard let runtime else { return }
    guard let directory = runtime.extensionsDirectory(forProfileID: profileID.uuidString) else {
      return
    }
    for item in extensions where icons[item.id] == nil {
      icons[item.id] = ExtensionIconLoader.icon(
        for: item.id, version: item.version, in: directory)
    }
  }
}
