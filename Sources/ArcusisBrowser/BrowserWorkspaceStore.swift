// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
  @ObservationIgnored private let faviconCache: FaviconCache?

  init(
    file: WorkspaceFile? = nil, initialSession: BrowserSession = .fresh(),
    faviconCache: FaviconCache? = nil
  ) throws {
    self.file = file
    self.faviconCache = faviconCache
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
        ShellL10n.string(
          "Saved windows could not be restored. The original files are preserved; changes in these temporary windows will not be saved."
        )
    }
    for window in workspace.windows { attach(window) }
    if isNew && maySave { persistSnapshot() }
  }

  @discardableResult
  func newWindow(from sourceID: UUID? = nil) throws -> UUID {
    let id = try workspace.addWindow(from: sourceID)
    attach(workspace.window(id)!)
    saveAndBroadcast()
    return id
  }

  @discardableResult
  func restoreWindow(_ closedWindow: WorkspaceWindow, from sourceID: UUID? = nil) throws -> UUID {
    let id = try workspace.restoreWindow(closedWindow, from: sourceID)
    attach(workspace.window(id)!)
    saveAndBroadcast()
    return id
  }

  func removeWindow(_ id: UUID) throws {
    try workspace.removeWindow(id)
    stores[id] = nil
    saveAndBroadcast()
  }

  func focusWindow(_ id: UUID) throws {
    guard workspace.focusedWindowID != id else { return }
    try workspace.focusWindow(id)
    saveAndBroadcast()
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
      name: profile.name, tint: profile.tint, customRGB: profile.customRGB, symbol: profile.symbol,
      id: profile.id)
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

  func setProfileSymbol(_ id: UUID, symbol: String) throws {
    try workspace.setProfileSymbol(id, symbol: symbol)
    saveAndBroadcast()
  }

  func setSpaceProfile(_ spaceID: UUID, to profileID: UUID) throws -> Bool {
    guard try workspace.setSpaceProfile(spaceID, to: profileID) else { return false }
    saveAndBroadcast()
    return true
  }

  func deleteProfile(_ id: UUID, movingSpacesTo destinationID: UUID?) throws {
    try workspace.deleteProfile(id, movingSpacesTo: destinationID)
    saveAndBroadcast()
  }

  func setGeometry(_ geometry: WorkspaceWindowGeometry, for id: UUID) throws {
    guard workspace.window(id)?.geometry != geometry else { return }
    try workspace.setGeometry(geometry, for: id)
    saveAndBroadcast()
  }

  /// Writes synchronously at lifecycle checkpoints: launch, native restoration and quit.
  /// IO failure leaves valid unsaved state live.
  @discardableResult
  func persistSnapshot() -> Bool {
    let saved = writeSnapshot()
    broadcast(excluding: nil)
    return saved
  }

  /// Confirms the current workspace can be written before a destructive profile operation.
  func validateWritableSnapshot() throws {
    try flushSaves()
    guard persistSnapshot() else { throw CocoaError(.fileWriteUnknown) }
  }

  /// Waits until the latest change is on disk. Ordinary changes return before the disk flush.
  func flushSaves() throws {
    do {
      try snapshotScheduler.flush()
    } catch {
      showSaveResult(failure: error.localizedDescription)
      throw error
    }
  }

  private func attach(_ window: WorkspaceWindow) {
    stores[window.id] = BrowserStore(managedSession: window.session, notice: storageNotice) {
      [weak self] session, deferred in
      guard let self else {
        return ManagedSessionSaveResult(
          session: session, notice: ShellL10n.string("The workspace is unavailable."))
      }
      return self.changed(window.id, session: session, deferred: deferred)
    }
    stores[window.id]?.faviconCache = faviconCache
    stores[window.id]?.sharedPinID = { [weak self] tabID in
      self?.workspace.window(window.id)?.pins.first { $0.tabID == tabID }?.pinID
    }
    stores[window.id]?.onSetSpaceProfile = { [weak self] spaceID, profileID in
      guard let self, self.stores[window.id] != nil else { return false }
      return (try? self.setSpaceProfile(spaceID, to: profileID)) ?? false
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
    stores[window.id]?.onTransferTabFromAnotherWindow = {
      [weak self]
      sessionID, tabID, sourceSpaceID, destinationSpaceID, beforeTabID, pinned,
      folderID in
      self?.transferTab(
        sessionID, tabID: tabID, from: sourceSpaceID, to: destinationSpaceID, in: window.id,
        before: beforeTabID, pinned: pinned, folderID: folderID) ?? false
    }
  }

  private func transferTab(
    _ sourceDragSessionID: UUID, tabID: UUID, from sourceSpaceID: UUID, to destinationSpaceID: UUID,
    in destinationWindowID: UUID, before targetTabID: UUID?, pinned: Bool?, folderID: UUID?
  ) -> Bool {
    guard let destinationStore = stores[destinationWindowID],
      let sourceWindow = workspace.windows.first(where: { window in
        window.id != destinationWindowID
          && window.session.spaces.contains { space in
            space.id == sourceSpaceID && space.tabs.contains { $0.id == tabID }
          }
      }),
      let sourceStore = stores[sourceWindow.id],
      sourceStore.dragSessionID == sourceDragSessionID,
      let sourceSpace = sourceWindow.session.spaces.first(where: { $0.id == sourceSpaceID }),
      let targetSpace = destinationStore.session.spaces.first(where: {
        $0.id == destinationSpaceID
      })
    else { return false }
    guard Self.canTransferTab(sourceStore: sourceStore, destinationStore: destinationStore) else {
      destinationStore.setSidebarNotice(
        ShellL10n.string("Tabs cannot move to or from a private window."))
      return false
    }
    guard let sourceTab = sourceSpace.tabs.first(where: { $0.id == tabID }) else { return false }
    guard !sourceTab.isPinned else {
      destinationStore.setSidebarNotice(
        ShellL10n.string("Pinned tabs cannot move between windows."))
      return false
    }
    let destinationFolderIsPinned =
      folderID.flatMap { folderID in
        targetSpace.folders.first(where: { $0.id == folderID })?.isPinned
      } ?? false
    guard pinned != true, !destinationFolderIsPinned else {
      destinationStore.setSidebarNotice(
        ShellL10n.string("Tabs cannot be dropped into the pinned section from another window."))
      return false
    }
    guard sourceSpace.profileID == targetSpace.profileID else {
      destinationStore.setSidebarNotice(
        ShellL10n.string(
          "Tabs can move only between spaces sharing a profile.")
      )
      return false
    }

    var sourceSession = sourceWindow.session
    var destinationSession = destinationStore.session
    guard
      sourceSession.transferTab(
        tabID, from: sourceSpaceID, to: &destinationSession,
        in: destinationSpaceID, before: targetTabID, pinned: pinned, folderID: folderID)
    else { return false }

    var updated = workspace
    do {
      try updated.updateWindow(sourceWindow.id, session: sourceSession)
      try updated.updateWindow(destinationWindowID, session: destinationSession)
      try updated.validate()
    } catch {
      return false
    }

    workspace = updated
    sourceStore.applyManagedSession(sourceSession, notice: storageNotice)
    destinationStore.applyManagedSession(destinationSession, notice: storageNotice)
    destinationStore.setSidebarNotice(nil)
    scheduleSnapshot(deferred: false)
    return true
  }

  static func canTransferTab(sourceStore: BrowserStore, destinationStore: BrowserStore)
    -> Bool
  {
    !sourceStore.isPrivate && !destinationStore.isPrivate
  }

  private func changed(_ id: UUID, session: BrowserSession, deferred: Bool)
    -> ManagedSessionSaveResult
  {
    guard stores[id] != nil, let previous = workspace.window(id) else {
      return ManagedSessionSaveResult(
        session: session,
        notice: ShellL10n.string("This window is closed; its changes will not be saved."))
    }
    do {
      try workspace.updateWindow(id, session: session)
    } catch {
      // A rejected identity/profile mutation must not reach the native engine.
      return ManagedSessionSaveResult(
        session: previous.session,
        notice: ShellL10n.format(
          "The window change was rejected. %@", arguments: [.string(error.localizedDescription)]))
    }
    scheduleSnapshot(deferred: deferred)
    if !deferred { broadcast(excluding: id) }
    return ManagedSessionSaveResult(session: workspace.window(id)!.session, notice: storageNotice)
  }

  private func saveAndBroadcast() {
    scheduleSnapshot(deferred: false)
    broadcast(excluding: nil)
  }

  @discardableResult
  private func writeSnapshot() -> Bool {
    guard maySave else { return false }
    faviconCache?.retain(workspace.faviconItemIDs)
    let snapshot = workspace
    do {
      try snapshotScheduler.writeNow { try file?.save(snapshot) }
      storageNotice = nil
      return true
    } catch {
      storageNotice = Self.saveNotice(failure: error.localizedDescription)
      return false
    }
  }

  /// Every change is flushed to disk off the main thread; deferred changes also coalesce.
  private func scheduleSnapshot(deferred: Bool) {
    guard maySave else { return }
    faviconCache?.retain(workspace.faviconItemIDs)
    guard let file else { return }
    let snapshot = workspace
    snapshotScheduler.schedule(
      deferred: deferred, { try file.save(snapshot) },
      completion: { [weak self] failure in self?.showSaveResult(failure: failure) })
  }

  private func showSaveResult(failure: String?) {
    let notice = Self.saveNotice(failure: failure)
    guard storageNotice != notice else { return }
    storageNotice = notice
    broadcast(excluding: nil)
  }

  private static func saveNotice(failure: String?) -> String? {
    failure.map { _ in ShellL10n.string("Window changes could not be saved. Try again.") }
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

extension BrowserWorkspace {
  /// Saved page IDs by profile: every placeholder can show its last icon at restart.
  fileprivate var faviconItemIDs: [UUID: Set<UUID>] {
    var itemIDs = Dictionary(grouping: catalog.favorites, by: \.profileID)
      .mapValues { Set($0.map(\.id)) }
    for space in catalog.spaces {
      itemIDs[space.profileID, default: []].formUnion(space.tabs.map(\.id))
    }
    for window in windows {
      for space in window.session.spaces {
        itemIDs[space.profileID, default: []].formUnion(space.tabs.map(\.id))
      }
    }
    return itemIDs
  }
}
