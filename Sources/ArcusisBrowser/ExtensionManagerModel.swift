import AppKit
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
  private var requestID = UUID()

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
    return model
  }

  private init(
    runtime: ARCChromiumRuntime, preferences: BrowserPreferencesStore, profileID: UUID
  ) {
    self.runtime = runtime
    self.preferences = preferences
    self.profileID = profileID
  }

  init(profileID: UUID, extensions: [ManagedExtension], pinnedIDs: [String] = []) {
    self.runtime = nil
    self.preferences = nil
    self.profileID = profileID
    self.extensions = extensions
    self.pinnedIDs = pinnedIDs
  }

  var pinnedExtensions: [ManagedExtension] {
    pinnedIDs.compactMap { id in extensions.first { $0.id == id && $0.enabled } }
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
        self.extensions = list.sorted {
          $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
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

  private func mutate(_ operation: ExtensionManagementOperation) {
    guard let runtime, ExtensionManagementOperation.isValidProfileID(profileID.uuidString) else {
      return
    }
    runtime.manageExtensions(operation, profileID: profileID) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
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
