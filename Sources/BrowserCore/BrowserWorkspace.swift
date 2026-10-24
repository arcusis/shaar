import Foundation

public enum WorkspaceError: Error, LocalizedError {
  case unsupportedVersion, invalidState, unknownWindow

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion: "The saved workspace version is unsupported."
    case .invalidState: "The workspace has conflicting window, Space, profile, or tab ownership."
    case .unknownWindow: "The window no longer belongs to this workspace."
    }
  }
}

/// Pin IDs identify shared definitions. They are not reusable native tab IDs.
public struct WorkspacePinReference: Codable, Equatable, Sendable {
  public let tabID: UUID
  public let pinID: UUID
}

public struct WorkspaceWindow: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public internal(set) var session: BrowserSession
  public internal(set) var pins: [WorkspacePinReference]
}

/// Contains shared metadata and original pin addresses, never window navigation or recovery state.
public struct WorkspaceCatalog: Codable, Equatable, Sendable {
  public internal(set) var profiles: [BrowserProfile]
  public internal(set) var spaces: [BrowserSpace]
}

public struct BrowserWorkspace: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public let version: Int
  public private(set) var catalog: WorkspaceCatalog
  public private(set) var windows: [WorkspaceWindow]
  public private(set) var focusedWindowID: UUID?

  public init(session: BrowserSession) throws {
    try session.validate()
    version = Self.currentVersion
    catalog = WorkspaceCatalog(
      profiles: session.profiles,
      spaces: session.spaces.map { source in
        var space = source
        space.tabs = source.tabs.filter(\.isPinned)
        space.selectedTabID = nil
        space.folders = source.folders.map(Self.sharedFolder)
        return space
      })
    let window = WorkspaceWindow(
      id: UUID(), session: session,
      pins: session.spaces.flatMap { $0.tabs.filter(\.isPinned) }.map {
        WorkspacePinReference(tabID: $0.id, pinID: $0.id)
      })
    windows = [window]
    focusedWindowID = window.id
    try validate()
  }

  private enum CodingKeys: String, CodingKey { case version, catalog, windows, focusedWindowID }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    guard version == Self.currentVersion else { throw WorkspaceError.unsupportedVersion }
    catalog = try values.decode(WorkspaceCatalog.self, forKey: .catalog)
    windows = try values.decode([WorkspaceWindow].self, forKey: .windows)
    focusedWindowID = try values.decodeIfPresent(UUID.self, forKey: .focusedWindowID)
    try validate()
  }

  public func window(_ id: UUID) -> WorkspaceWindow? { windows.first { $0.id == id } }

  public func validate() throws {
    guard version == Self.currentVersion else { throw WorkspaceError.unsupportedVersion }
    guard let first = catalog.spaces.first else { throw WorkspaceError.invalidState }
    try BrowserSession(
      profiles: catalog.profiles, spaces: catalog.spaces, selectedSpaceID: first.id
    ).validate()
    guard
      catalog.spaces.allSatisfy({
        $0.selectedTabID == nil && $0.tabs.allSatisfy(\.isPinned)
          && $0.folders.allSatisfy { !$0.isCollapsed }
      }), Set(windows.map(\.id)).count == windows.count,
      windows.isEmpty
        ? focusedWindowID == nil : windows.contains(where: { $0.id == focusedWindowID })
    else { throw WorkspaceError.invalidState }
    let definitions = Dictionary(
      uniqueKeysWithValues: catalog.spaces.flatMap { space in space.tabs.map { ($0.id, space) } })
    var claimed: Set<UUID> = []
    for window in windows {
      try window.session.validate()
      guard window.session.profiles == catalog.profiles,
        window.session.spaces.map(Self.spaceMetadata) == catalog.spaces.map(Self.spaceMetadata),
        window.pins.count == definitions.count,
        Set(window.pins.map(\.tabID)).count == window.pins.count,
        Set(window.pins.map(\.pinID)) == Set(definitions.keys)
      else { throw WorkspaceError.invalidState }
      let bindings = Dictionary(uniqueKeysWithValues: window.pins.map { ($0.tabID, $0.pinID) })
      let localTabs = window.session.spaces.flatMap(\.tabs)
      guard Set(bindings.keys) == Set(localTabs.filter(\.isPinned).map(\.id)) else {
        throw WorkspaceError.invalidState
      }
      for id in localTabs.map(\.id) + window.session.closedTabs.map(\.id) {
        guard claimed.insert(id).inserted else { throw WorkspaceError.invalidState }
      }
      for space in window.session.spaces {
        let pins = space.tabs.filter(\.isPinned)
        guard
          pins.compactMap({ bindings[$0.id] })
            == catalog.spaces.first(where: { $0.id == space.id })!.tabs.map(\.id),
          pins.allSatisfy({ tab in
            guard let pinID = bindings[tab.id], let owner = definitions[pinID],
              let definition = owner.tabs.first(where: { $0.id == pinID })
            else { return false }
            return owner.id == space.id && owner.profileID == space.profileID
              && definition.folderID == tab.folderID
          })
        else { throw WorkspaceError.invalidState }
      }
    }
  }

  /// New windows share definitions/accounts, not another window's live pages or recovery list.
  @discardableResult
  public mutating func addWindow(from sourceID: UUID? = nil) throws -> UUID {
    if let sourceID, window(sourceID) == nil { throw WorkspaceError.unknownWindow }
    var draft = self
    var allocated = allocatedIDs
    let source = sourceID.flatMap(window)
    let empty = try BrowserSession(
      profiles: catalog.profiles,
      spaces: catalog.spaces.map { definition in
        var space = definition
        space.tabs = []
        space.selectedTabID = nil
        return space
      }, selectedSpaceID: source?.session.selectedSpaceID ?? catalog.spaces[0].id)
    let id = Self.allocate(&allocated)
    let projected = try draft.project(
      WorkspaceWindow(id: id, session: empty, pins: []), allocated: &allocated)
    draft.windows.append(projected)
    draft.focusedWindowID = id
    try draft.validate()
    self = draft
    return id
  }

  public mutating func focusWindow(_ id: UUID) throws {
    guard window(id) != nil else { throw WorkspaceError.unknownWindow }
    focusedWindowID = id
  }

  /// Ordinary closure removes only that window. App quit should retain open-window records.
  public mutating func removeWindow(_ id: UUID) throws {
    guard window(id) != nil else { throw WorkspaceError.unknownWindow }
    windows.removeAll { $0.id == id }
    if focusedWindowID == id { focusedWindowID = windows.last?.id }
  }

  public mutating func updateWindow(_ id: UUID, session: BrowserSession) throws {
    guard let index = windows.firstIndex(where: { $0.id == id }) else {
      throw WorkspaceError.unknownWindow
    }
    try session.validate()
    let previous = windows[index]
    let previousProfiles = Set(catalog.profiles.map(\.id))
    guard previousProfiles.isSubset(of: Set(session.profiles.map(\.id))) else {
      throw WorkspaceError.invalidState
    }
    let oldSpaces = Dictionary(uniqueKeysWithValues: catalog.spaces.map { ($0.id, $0) })
    let oldOwners = Self.tabProfiles(previous.session)
    let newOwners = Self.tabProfiles(session)
    // Explicit comparisons keep immutable account ownership separate from mutable metadata.
    for space in session.spaces {
      if let old = oldSpaces[space.id], old.profileID != space.profileID {
        throw WorkspaceError.invalidState
      }
    }
    for (tab, owner) in newOwners {
      if let old = oldOwners[tab], old != owner { throw WorkspaceError.invalidState }
    }
    let oldFolderOwners = Dictionary(
      uniqueKeysWithValues: catalog.spaces.flatMap { space in
        space.folders.map { ($0.id, space.profileID) }
      })
    for space in session.spaces {
      for folder in space.folders {
        if let old = oldFolderOwners[folder.id], old != space.profileID {
          throw WorkspaceError.invalidState
        }
      }
    }
    var draft = self
    var allocated = allocatedIDs.union(session.spaces.flatMap { $0.tabs.map(\.id) }).union(
      session.closedTabs.map(\.id))
    let oldBindings = Dictionary(uniqueKeysWithValues: previous.pins.map { ($0.tabID, $0.pinID) })
    let oldDefinitions = Dictionary(
      uniqueKeysWithValues: catalog.spaces.flatMap(\.tabs).map { ($0.id, $0) })
    var references: [WorkspacePinReference] = []
    let spaces = session.spaces.map { source in
      var space = source
      space.selectedTabID = nil
      space.folders = source.folders.map(Self.sharedFolder)
      space.tabs = source.tabs.filter(\.isPinned).map { tab in
        let pinID = oldBindings[tab.id] ?? Self.allocate(&allocated)
        references.append(WorkspacePinReference(tabID: tab.id, pinID: pinID))
        let definition = oldDefinitions[pinID]
        return BrowserTab(
          id: pinID, url: definition?.url ?? tab.url, title: definition?.title ?? tab.title,
          isPinned: true, folderID: tab.folderID)
      }
      return space
    }
    draft.catalog = WorkspaceCatalog(profiles: session.profiles, spaces: spaces)
    draft.windows[index] = WorkspaceWindow(id: id, session: session, pins: references)
    if draft.catalog != catalog {
      for other in draft.windows.indices where other != index {
        draft.windows[other] = try draft.project(draft.windows[other], allocated: &allocated)
      }
    }
    try draft.validate()
    self = draft
  }

  private var allocatedIDs: Set<UUID> {
    Set(
      windows.map(\.id) + catalog.spaces.flatMap { $0.tabs.map(\.id) }
        + windows.flatMap {
          $0.session.spaces.flatMap { $0.tabs.map(\.id) } + $0.session.closedTabs.map(\.id)
        })
  }

  private func project(_ old: WorkspaceWindow, allocated: inout Set<UUID>) throws -> WorkspaceWindow
  {
    let oldTabs = Dictionary(
      uniqueKeysWithValues: old.session.spaces.flatMap(\.tabs).map { ($0.id, $0) })
    let bindings = Dictionary(uniqueKeysWithValues: old.pins.map { ($0.pinID, $0.tabID) })
    let definitions = Set(catalog.spaces.flatMap { $0.tabs.map(\.id) })
    let retainedPins = Set(old.pins.filter { definitions.contains($0.pinID) }.map(\.tabID))
    let collapsed = Dictionary(
      uniqueKeysWithValues: old.session.spaces.flatMap(\.folders).map { ($0.id, $0.isCollapsed) })
    var references: [WorkspacePinReference] = []
    var spaces = catalog.spaces.map { definition in
      let prior = old.session.spaces.first { $0.id == definition.id }
      var space = definition
      space.folders = definition.folders.map {
        var folder = $0
        folder.isCollapsed = collapsed[folder.id] ?? false
        return folder
      }
      space.tabs = definition.tabs.map { pin in
        var tab =
          bindings[pin.id].flatMap { oldTabs[$0] }
          ?? BrowserTab(id: Self.allocate(&allocated), url: pin.url, title: pin.title)
        tab.isPinned = true
        tab.folderID = pin.folderID
        references.append(WorkspacePinReference(tabID: tab.id, pinID: pin.id))
        return tab
      }
      space.tabs += (prior?.tabs ?? []).filter { !retainedPins.contains($0.id) }.map {
        var tab = $0
        // Removing a shared pin keeps another window's existing live document as an ordinary tab.
        tab.isPinned = false
        tab.folderID = nil
        return tab
      }
      space.selectedTabID = prior?.selectedTabID.flatMap { id in
        space.tabs.contains { $0.id == id } ? id : nil
      }
      return space
    }
    var selectedSpace =
      spaces.contains { $0.id == old.session.selectedSpaceID }
      ? old.session.selectedSpaceID : spaces[0].id
    if let selected = old.session.selectedSpace.selectedTabID,
      let destination = spaces.firstIndex(where: { $0.tabs.contains { $0.id == selected } })
    {
      selectedSpace = spaces[destination].id
      spaces[destination].selectedTabID = selected
    }
    var session = try BrowserSession(
      profiles: catalog.profiles, spaces: spaces, selectedSpaceID: selectedSpace)
    session.closedTabs = old.session.closedTabs.filter { entry in
      spaces.contains { $0.id == entry.spaceID && $0.profileID == entry.profileID }
    }
    return WorkspaceWindow(id: old.id, session: session, pins: references)
  }

  private static func allocate(_ used: inout Set<UUID>) -> UUID {
    while true {
      let id = UUID()
      if used.insert(id).inserted { return id }
    }
  }

  private static func sharedFolder(_ source: BrowserFolder) -> BrowserFolder {
    var folder = source
    folder.isCollapsed = false
    return folder
  }

  private static func spaceMetadata(_ source: BrowserSpace) -> BrowserSpace {
    var space = source
    space.tabs = []
    space.selectedTabID = nil
    space.folders = source.folders.map(sharedFolder)
    return space
  }

  private static func tabProfiles(_ session: BrowserSession) -> [UUID: UUID] {
    Dictionary(
      uniqueKeysWithValues: session.spaces.flatMap { space in
        space.tabs.map { ($0.id, space.profileID) }
      }
        + session.closedTabs.map { ($0.id, $0.profileID) })
  }
}
