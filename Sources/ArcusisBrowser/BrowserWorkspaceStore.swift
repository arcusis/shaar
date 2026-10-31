import BrowserCore
import Foundation
import Observation

/// One in-process writer coordinates all normal window models. Native window lifecycle is separate.
@MainActor @Observable
final class BrowserWorkspaceStore {
  private(set) var workspace: BrowserWorkspace
  private(set) var storageNotice: String?
  @ObservationIgnored private(set) var stores: [UUID: BrowserStore] = [:]
  @ObservationIgnored private let file: WorkspaceFile?
  @ObservationIgnored private var maySave = true
  @ObservationIgnored private let snapshotScheduler = SnapshotSaveScheduler()

  init(file: WorkspaceFile? = nil, initialSession: BrowserSession = .fresh()) throws {
    self.file = file
    workspace = try BrowserWorkspace(session: initialSession)
    var isNew = true
    do {
      if let restored = try file?.load() {
        workspace = restored
        isNew = false
      }
    } catch {
      maySave = false
      storageNotice =
        "Saved windows could not be restored. The original files are preserved; changes in these temporary windows will not be saved."
    }
    for window in workspace.windows { attach(window) }
    if isNew && maySave { persistSnapshot() }
  }

  @discardableResult
  func newWindow(from sourceID: UUID? = nil) throws -> UUID {
    let id = try workspace.addWindow(from: sourceID)
    attach(workspace.window(id)!)
    persistSnapshot()
    return id
  }

  func removeWindow(_ id: UUID) throws {
    try workspace.removeWindow(id)
    stores[id] = nil
    persistSnapshot()
  }

  func focusWindow(_ id: UUID) throws {
    guard workspace.focusedWindowID != id else { return }
    try workspace.focusWindow(id)
    persistSnapshot()
  }

  @discardableResult
  func createProfile(name: String) throws -> UUID {
    try createProfile(BrowserProfile(name: name))
  }

  /// Creates the profile with its chosen identity and color, and optionally gives it a Space, as
  /// one saved change.
  @discardableResult
  func createProfile(_ profile: BrowserProfile, assigningSpace spaceID: UUID? = nil) throws -> UUID
  {
    var updated = workspace
    let id = try updated.createProfile(
      name: profile.name, tint: profile.tint, customRGB: profile.customRGB, id: profile.id)
    if let spaceID, try !updated.setSpaceProfile(spaceID, to: id) {
      throw WorkspaceError.invalidState
    }
    workspace = updated
    saveAndBroadcast()
    return id
  }

  func renameProfile(_ id: UUID, name: String) throws {
    try workspace.renameProfile(id, name: name)
    saveAndBroadcast()
  }

  func setProfileColor(_ id: UUID, tint: SpaceTint?, customRGB: SpaceRGBColor?) throws {
    try workspace.setProfileColor(id, tint: tint, customRGB: customRGB)
    saveAndBroadcast()
  }

  func setSpaceProfile(_ spaceID: UUID, to profileID: UUID) throws -> Bool {
    guard try workspace.setSpaceProfile(spaceID, to: profileID) else { return false }
    saveAndBroadcast()
    return true
  }

  func deleteProfile(_ id: UUID, movingSpacesTo destinationID: UUID) throws {
    try workspace.deleteProfile(id, movingSpacesTo: destinationID)
    saveAndBroadcast()
  }

  func setGeometry(_ geometry: WorkspaceWindowGeometry, for id: UUID) throws {
    guard workspace.window(id)?.geometry != geometry else { return }
    try workspace.setGeometry(geometry, for: id)
    persistSnapshot()
  }

  /// Called before native restoration as well as after mutations. IO failure leaves valid unsaved state live.
  @discardableResult
  func persistSnapshot() -> Bool {
    let saved = writeSnapshot()
    broadcast(excluding: nil)
    return saved
  }

  private func attach(_ window: WorkspaceWindow) {
    stores[window.id] = BrowserStore(managedSession: window.session, notice: storageNotice) {
      [weak self] session, deferred in
      guard let self else {
        return ManagedSessionSaveResult(session: session, notice: "The workspace is unavailable.")
      }
      return self.changed(window.id, session: session, deferred: deferred)
    }
    stores[window.id]?.onSetSpaceProfile = { [weak self] spaceID, profileID in
      (try? self?.setSpaceProfile(spaceID, to: profileID)) ?? false
    }
    stores[window.id]?.onSpaceRemovalImpact = { [weak self] id in
      let spaces =
        self?.workspace.windows.compactMap { $0.session.spaces.first { $0.id == id } } ?? []
      guard let self,
        let definition = self.workspace.catalog.spaces.first(where: { $0.id == id })
      else { return SpaceRemovalImpact(tabs: 0, windows: 0) }
      let isLastProfileSpace =
        self.workspace.catalog.spaces.filter {
          $0.profileID == definition.profileID
        }.count == 1
      let favoritePages =
        isLastProfileSpace
        ? self.workspace.windows.reduce(0) { count, window in
          count
            + window.session.favoritePages.filter {
              window.session.profileID(forTabID: $0.tab.id) == definition.profileID
            }.count
        }
        : 0
      return SpaceRemovalImpact(
        tabs: spaces.reduce(0) { $0 + $1.tabs.count }, windows: spaces.count,
        favoritePages: favoritePages)
    }
  }

  private func changed(_ id: UUID, session: BrowserSession, deferred: Bool)
    -> ManagedSessionSaveResult
  {
    guard stores[id] != nil, let previous = workspace.window(id) else {
      return ManagedSessionSaveResult(
        session: session, notice: "This window is closed; its changes will not be saved.")
    }
    do {
      try workspace.updateWindow(id, session: session)
    } catch {
      // A rejected identity/profile mutation must not reach the native engine.
      return ManagedSessionSaveResult(
        session: previous.session,
        notice: "The window change was rejected. \(error.localizedDescription)")
    }
    if deferred {
      scheduleSnapshot()
    } else {
      writeSnapshot()
      broadcast(excluding: id)
    }
    return ManagedSessionSaveResult(session: workspace.window(id)!.session, notice: storageNotice)
  }

  private func saveAndBroadcast() {
    _ = writeSnapshot()
    broadcast(excluding: nil)
  }

  @discardableResult
  private func writeSnapshot() -> Bool {
    guard maySave else { return false }
    do {
      let snapshot = workspace
      try snapshotScheduler.writeNow { try file?.save(snapshot) }
      storageNotice = nil
      return true
    } catch {
      storageNotice = "Window changes could not be saved. \(error.localizedDescription)"
      return false
    }
  }

  private func scheduleSnapshot() {
    guard maySave, let file else { return }
    let snapshot = workspace
    snapshotScheduler.schedule(
      { try file.save(snapshot) },
      completion: { [weak self] error in
        guard let self else { return }
        let notice = error.map { "Window changes could not be saved. \($0)" }
        guard self.storageNotice != notice else { return }
        self.storageNotice = notice
        self.broadcast(excluding: nil)
      })
  }

  private func broadcast(excluding sourceID: UUID?) {
    // A native metadata callback can occur during reconciliation. Read each latest
    // record immediately before delivery so an outer broadcast cannot overwrite it.
    for id in Array(stores.keys) where id != sourceID {
      guard let current = workspace.window(id) else { continue }
      stores[id]?.applyManagedSession(current.session, notice: storageNotice)
    }
  }
}
