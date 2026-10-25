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
    let id = try workspace.createProfile(name: name)
    _ = writeSnapshot()
    broadcast(excluding: nil)
    return id
  }

  func renameProfile(_ id: UUID, name: String) throws {
    try workspace.renameProfile(id, name: name)
    _ = writeSnapshot()
    broadcast(excluding: nil)
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
      [weak self] session in
      guard let self else {
        return ManagedSessionSaveResult(session: session, notice: "The workspace is unavailable.")
      }
      return self.changed(window.id, session: session)
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

  private func changed(_ id: UUID, session: BrowserSession) -> ManagedSessionSaveResult {
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
    writeSnapshot()
    broadcast(excluding: id)
    return ManagedSessionSaveResult(session: workspace.window(id)!.session, notice: storageNotice)
  }

  @discardableResult
  private func writeSnapshot() -> Bool {
    guard maySave else { return false }
    do {
      try file?.save(workspace)
      storageNotice = nil
      return true
    } catch {
      storageNotice = "Window changes could not be saved. \(error.localizedDescription)"
      return false
    }
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
