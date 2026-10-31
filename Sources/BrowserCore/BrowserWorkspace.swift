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
  public internal(set) var geometry: WorkspaceWindowGeometry? = nil
}

public struct WorkspaceWindowGeometry: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var isValid: Bool {
    [x, y, width, height].allSatisfy(\.isFinite) && width >= 760 && height >= 520
  }
}

/// Contains shared metadata and original pin addresses, never window navigation or recovery state.
public struct WorkspaceCatalog: Codable, Equatable, Sendable {
  public internal(set) var profiles: [BrowserProfile]
  public internal(set) var spaces: [BrowserSpace]
  public internal(set) var favorites: [BrowserFavorite]
}

private struct LegacyWorkspaceCatalog: Decodable {
  let profiles: [BrowserProfile]
  let spaces: [BrowserSpace]

  private enum CodingKeys: String, CodingKey { case profiles, spaces, favorites }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard !values.contains(.favorites) else { throw WorkspaceError.invalidState }
    profiles = try values.decode([BrowserProfile].self, forKey: .profiles)
    spaces = try values.decode([BrowserSpace].self, forKey: .spaces)
  }
}

private struct LegacyWorkspaceWindow: Decodable {
  let id: UUID
  let session: BrowserSession
  let pins: [WorkspacePinReference]
  let geometry: WorkspaceWindowGeometry?
}

public struct BrowserWorkspace: Codable, Equatable, Sendable {
  public static let currentVersion = 2
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
        space.splits = []
        space.selectedTabID = nil
        space.selectedFavoriteID = nil
        space.folders = source.folders.map(Self.sharedFolder)
        return space
      }, favorites: session.favorites)
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
    let sourceVersion = try values.decode(Int.self, forKey: .version)
    guard [1, Self.currentVersion].contains(sourceVersion) else {
      throw WorkspaceError.unsupportedVersion
    }
    version = Self.currentVersion
    if sourceVersion == 1 {
      let legacyCatalog = try values.decode(LegacyWorkspaceCatalog.self, forKey: .catalog)
      catalog = WorkspaceCatalog(
        profiles: legacyCatalog.profiles, spaces: legacyCatalog.spaces, favorites: [])
      windows = try values.decode([LegacyWorkspaceWindow].self, forKey: .windows).map {
        WorkspaceWindow(id: $0.id, session: $0.session, pins: $0.pins, geometry: $0.geometry)
      }
      focusedWindowID = try values.decodeIfPresent(UUID.self, forKey: .focusedWindowID)
    } else {
      catalog = try values.decode(WorkspaceCatalog.self, forKey: .catalog)
      windows = try values.decode([WorkspaceWindow].self, forKey: .windows)
      focusedWindowID = try values.decodeIfPresent(UUID.self, forKey: .focusedWindowID)
    }
    try validate()
  }

  public func window(_ id: UUID) -> WorkspaceWindow? { windows.first { $0.id == id } }

  public func favorites(for profileID: UUID) -> [BrowserFavorite] {
    catalog.favorites.filter { $0.profileID == profileID }
  }

  @discardableResult
  public mutating func addFavorite(
    windowID: UUID, profileID: UUID, originalURL: URL, title: String? = nil, id: UUID = UUID()
  ) throws -> UUID? {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard
      let favoriteID = session.addFavorite(
        profileID: profileID, originalURL: originalURL, title: title, id: id)
    else { return nil }
    try updateWindow(windowID, session: session)
    return favoriteID
  }

  @discardableResult
  public mutating func moveFavorite(
    windowID: UUID, favoriteID: UUID, in profileID: UUID, before targetID: UUID? = nil
  ) throws -> Bool {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard session.moveFavorite(favoriteID, in: profileID, before: targetID) else { return false }
    try updateWindow(windowID, session: session)
    return true
  }

  @discardableResult
  public mutating func openFavorite(windowID: UUID, favoriteID: UUID) throws -> UUID? {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard let tabID = session.openFavorite(favoriteID) else { return nil }
    try updateWindow(windowID, session: session)
    return tabID
  }

  @discardableResult
  public mutating func selectFavorite(
    windowID: UUID, favoriteID: UUID, in spaceID: UUID
  ) throws -> Bool {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard session.selectFavorite(favoriteID, in: spaceID) else { return false }
    try updateWindow(windowID, session: session)
    return true
  }

  @discardableResult
  public mutating func updateFavoritePage(
    windowID: UUID, favoriteID: UUID, url: URL, title: String
  ) throws -> Bool {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard session.updateFavoritePage(favoriteID, url: url, title: title) else { return false }
    try updateWindow(windowID, session: session)
    return true
  }

  @discardableResult
  public mutating func closeFavoritePage(windowID: UUID, favoriteID: UUID) throws -> Bool {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard session.closeFavoritePage(favoriteID) else { return false }
    try updateWindow(windowID, session: session)
    return true
  }

  /// Disposition applies only in source window; peer pages survive as ordinary tabs.
  @discardableResult
  public mutating func removeFavorite(
    windowID: UUID, favoriteID: UUID, disposition: FavoritePageDisposition
  ) throws -> Bool {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard session.removeFavorite(favoriteID, disposition: disposition) else { return false }
    try updateWindow(windowID, session: session)
    return true
  }

  @discardableResult
  public mutating func removeSpace(
    _ spaceID: UUID, windowID: UUID, favoriteDisposition: FavoritePageDisposition
  ) throws -> Bool {
    guard var session = window(windowID)?.session else { throw WorkspaceError.unknownWindow }
    guard session.removeSpace(spaceID, favoriteDisposition: favoriteDisposition) else {
      return false
    }
    try updateWindow(windowID, session: session)
    return true
  }

  /// Reassigns shared Space metadata and every window in one validated transaction.
  @discardableResult
  public mutating func setSpaceProfile(_ spaceID: UUID, to profileID: UUID) throws -> Bool {
    guard catalog.profiles.contains(where: { $0.id == profileID }),
      let index = catalog.spaces.firstIndex(where: { $0.id == spaceID })
    else { return false }
    guard catalog.spaces[index].profileID != profileID else { return true }
    var draft = self
    draft.catalog.spaces[index].profileID = profileID
    for windowIndex in draft.windows.indices {
      guard draft.windows[windowIndex].session.setSpaceProfile(spaceID, to: profileID) else {
        throw WorkspaceError.invalidState
      }
    }
    try draft.validate()
    self = draft
    return true
  }

  public func validate() throws {
    guard version == Self.currentVersion else { throw WorkspaceError.unsupportedVersion }
    guard let first = catalog.spaces.first else { throw WorkspaceError.invalidState }
    let catalogSession = try BrowserSession(
      profiles: catalog.profiles, spaces: catalog.spaces, selectedSpaceID: first.id,
      favorites: catalog.favorites)
    try catalogSession.validate()
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
    let favorites = Dictionary(uniqueKeysWithValues: catalog.favorites.map { ($0.id, $0) })
    var claimed: Set<UUID> = []
    for window in windows {
      guard window.geometry?.isValid != false else { throw WorkspaceError.invalidState }
      try window.session.validate()
      guard window.session.profiles == catalog.profiles,
        window.session.spaces.map(Self.spaceMetadata) == catalog.spaces.map(Self.spaceMetadata),
        window.session.favorites == catalog.favorites,
        window.pins.count == definitions.count,
        Set(window.pins.map(\.tabID)).count == window.pins.count,
        Set(window.pins.map(\.pinID)) == Set(definitions.keys)
      else { throw WorkspaceError.invalidState }
      let bindings = Dictionary(uniqueKeysWithValues: window.pins.map { ($0.tabID, $0.pinID) })
      let localTabs = window.session.spaces.flatMap(\.tabs)
      guard Set(bindings.keys) == Set(localTabs.filter(\.isPinned).map(\.id)) else {
        throw WorkspaceError.invalidState
      }
      for id in localTabs.map(\.id) + window.session.closedTabs.map(\.id)
        + window.session.favoritePages.map(\.tab.id)
      {
        guard claimed.insert(id).inserted else { throw WorkspaceError.invalidState }
      }
      guard window.session.favoritePages.count <= catalog.favorites.count,
        window.session.favoritePages.allSatisfy({ page in
          guard let favorite = favorites[page.favoriteID] else { return false }
          return catalog.spaces.contains(where: { $0.profileID == favorite.profileID })
        })
      else { throw WorkspaceError.invalidState }
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
    var emptyFavoritePages: [BrowserFavoritePage] = []
    for favorite in catalog.favorites
    where catalog.spaces.contains(where: { $0.profileID == favorite.profileID }) {
      emptyFavoritePages.append(
        BrowserFavoritePage(
          favoriteID: favorite.id,
          tab: BrowserTab(
            id: Self.allocate(&allocated), url: favorite.originalURL, title: favorite.title)))
    }
    let empty = try BrowserSession(
      profiles: catalog.profiles,
      spaces: catalog.spaces.map { definition in
        var space = definition
        space.tabs = []
        space.splits = []
        space.selectedTabID = nil
        space.selectedFavoriteID = nil
        return space
      }, selectedSpaceID: source?.session.selectedSpaceID ?? catalog.spaces[0].id,
      favorites: catalog.favorites, favoritePages: emptyFavoritePages)
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

  /// Adds an unused account profile without changing any live window session state. A caller
  /// may choose the identity up front so engine storage prepared before creation stays attached.
  @discardableResult
  public mutating func createProfile(
    name: String, tint: SpaceTint? = nil, customRGB: SpaceRGBColor? = nil, id: UUID = UUID()
  ) throws -> UUID {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty, !catalog.profiles.contains(where: { $0.id == id }) else {
      throw WorkspaceError.invalidState
    }
    var draft = self
    draft.catalog.profiles.append(
      BrowserProfile(id: id, name: cleanName, tint: tint, customRGB: customRGB))
    try draft.projectAllWindows()
    self = draft
    return id
  }

  /// Renames shared profile metadata while retaining its immutable identity.
  public mutating func renameProfile(_ id: UUID, name: String) throws {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else { throw WorkspaceError.invalidState }
    try updateProfile(id) { $0.name = cleanName }
  }

  /// Sets or clears a profile's color; a custom color takes precedence over the preset tint.
  public mutating func setProfileColor(
    _ id: UUID, tint: SpaceTint?, customRGB: SpaceRGBColor?
  ) throws {
    try updateProfile(id) { profile in
      profile.tint = tint
      profile.customRGB = customRGB
    }
  }

  private mutating func updateProfile(_ id: UUID, change: (inout BrowserProfile) -> Void) throws {
    guard let index = catalog.profiles.firstIndex(where: { $0.id == id }) else {
      throw WorkspaceError.invalidState
    }
    var draft = self
    change(&draft.catalog.profiles[index])
    guard draft.windows.allSatisfy({ $0.session.profiles.contains(where: { $0.id == id }) }) else {
      throw WorkspaceError.invalidState
    }
    try draft.projectAllWindows()
    self = draft
  }

  private mutating func projectAllWindows() throws {
    var allocated = allocatedIDs
    for index in windows.indices {
      windows[index] = try project(windows[index], allocated: &allocated)
    }
    try validate()
  }

  /// Deletes a profile and moves its Spaces to an existing profile atomically.
  public mutating func deleteProfile(_ id: UUID, movingSpacesTo destinationID: UUID) throws {
    guard catalog.profiles.count > 1, id != destinationID,
      catalog.profiles.contains(where: { $0.id == id }),
      catalog.profiles.contains(where: { $0.id == destinationID })
    else { throw WorkspaceError.invalidState }
    var draft = self
    for space in draft.catalog.spaces.filter({ $0.profileID == id }) {
      guard try draft.setSpaceProfile(space.id, to: destinationID) else {
        throw WorkspaceError.invalidState
      }
    }
    draft.catalog.favorites.removeAll { $0.profileID == id }
    draft.catalog.profiles.removeAll { $0.id == id }
    try draft.projectAllWindows()
    self = draft
  }

  public mutating func setGeometry(_ geometry: WorkspaceWindowGeometry, for id: UUID) throws {
    guard geometry.isValid else { throw WorkspaceError.invalidState }
    guard let index = windows.firstIndex(where: { $0.id == id }) else {
      throw WorkspaceError.unknownWindow
    }
    windows[index].geometry = geometry
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
    let oldFavoriteOwners = Dictionary(
      uniqueKeysWithValues: catalog.favorites.map { ($0.id, $0.profileID) })
    for favorite in session.favorites {
      if let oldOwner = oldFavoriteOwners[favorite.id], oldOwner != favorite.profileID {
        throw WorkspaceError.invalidState
      }
    }
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
      session.closedTabs.map(\.id)
    ).union(session.favoritePages.map(\.tab.id))
    let oldBindings = Dictionary(uniqueKeysWithValues: previous.pins.map { ($0.tabID, $0.pinID) })
    let oldDefinitions = Dictionary(
      uniqueKeysWithValues: catalog.spaces.flatMap(\.tabs).map { ($0.id, $0) })
    var references: [WorkspacePinReference] = []
    let spaces = session.spaces.map { source in
      var space = source
      space.selectedTabID = nil
      space.selectedFavoriteID = nil
      space.folders = source.folders.map(Self.sharedFolder)
      space.splits = []
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
    draft.catalog = WorkspaceCatalog(
      profiles: session.profiles, spaces: spaces, favorites: session.favorites)
    draft.windows[index] = WorkspaceWindow(
      id: id, session: session, pins: references, geometry: previous.geometry)
    if draft.catalog != catalog {
      for other in draft.windows.indices where other != index {
        draft.windows[other] = try draft.project(draft.windows[other], allocated: &allocated)
      }
    }
    try draft.validate()
    self = draft
  }

  private var allocatedIDs: Set<UUID> {
    var allocated = Set(windows.map(\.id))
    for space in catalog.spaces {
      allocated.formUnion(space.tabs.map(\.id))
    }
    for window in windows {
      for space in window.session.spaces {
        allocated.formUnion(space.tabs.map(\.id))
      }
      allocated.formUnion(window.session.closedTabs.map(\.id))
      allocated.formUnion(window.session.favoritePages.map(\.tab.id))
    }
    return allocated
  }

  private func project(_ old: WorkspaceWindow, allocated: inout Set<UUID>) throws -> WorkspaceWindow
  {
    let oldTabs = Dictionary(
      uniqueKeysWithValues: old.session.spaces.flatMap(\.tabs).map { ($0.id, $0) })
    let oldFavorites = Dictionary(uniqueKeysWithValues: old.session.favorites.map { ($0.id, $0) })
    let oldFavoritePages = Dictionary(
      uniqueKeysWithValues: old.session.favoritePages.map { ($0.favoriteID, $0) })
    let bindings = Dictionary(uniqueKeysWithValues: old.pins.map { ($0.pinID, $0.tabID) })
    let definitions = Set(catalog.spaces.flatMap { $0.tabs.map(\.id) })
    let retainedPins = Set(old.pins.filter { definitions.contains($0.pinID) }.map(\.tabID))
    let collapsed = Dictionary(
      uniqueKeysWithValues: old.session.spaces.flatMap(\.folders).map { ($0.id, $0.isCollapsed) })
    var references: [WorkspacePinReference] = []
    var spaces = catalog.spaces.map { definition in
      let prior = old.session.spaces.first { $0.id == definition.id }
      var space = definition
      space.selectedFavoriteID = prior?.selectedFavoriteID.flatMap { id in
        catalog.favorites.contains(where: { $0.id == id && $0.profileID == definition.profileID })
          ? id : nil
      }
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
      space.splits = prior?.splits ?? []
      space.reconcileSplits()
      space.selectedTabID = prior?.selectedTabID.flatMap { id in
        space.tabs.contains { $0.id == id } ? id : nil
      }
      return space
    }
    let newFavoriteIDs = Set(catalog.favorites.map(\.id))
    var favoritePages: [BrowserFavoritePage] = []
    var removedSelectedPage: (favoriteID: UUID, tab: BrowserTab, profileID: UUID)?
    for page in old.session.favoritePages where !newFavoriteIDs.contains(page.favoriteID) {
      guard let favorite = oldFavorites[page.favoriteID],
        let preferredSpace = old.session.spaces.first(where: {
          $0.id == old.session.selectedSpaceID && $0.profileID == favorite.profileID
        }) ?? old.session.spaces.first(where: { $0.selectedFavoriteID == page.favoriteID })
          ?? old.session.spaces.first(where: { $0.profileID == favorite.profileID }),
        let destination = spaces.firstIndex(where: {
          $0.id == preferredSpace.id && $0.profileID == favorite.profileID
        }) ?? spaces.firstIndex(where: { $0.profileID == favorite.profileID })
      else { continue }
      var tab = page.tab
      tab.isPinned = false
      tab.folderID = nil
      spaces[destination].tabs.append(tab)
      if old.session.spaces.contains(where: { $0.selectedFavoriteID == page.favoriteID }) {
        spaces[destination].selectedTabID = tab.id
        if old.session.selectedSpace.selectedFavoriteID == page.favoriteID {
          removedSelectedPage = (page.favoriteID, tab, favorite.profileID)
        }
      }
    }
    for favorite in catalog.favorites
    where spaces.contains(where: { $0.profileID == favorite.profileID }) {
      if let page = oldFavoritePages[favorite.id] {
        favoritePages.append(page)
      } else if oldFavorites[favorite.id] == nil {
        favoritePages.append(
          BrowserFavoritePage(
            favoriteID: favorite.id,
            tab: BrowserTab(
              id: Self.allocate(&allocated), url: favorite.originalURL, title: favorite.title)))
      }
    }
    var selectedSpace =
      spaces.contains { $0.id == old.session.selectedSpaceID }
      ? old.session.selectedSpaceID : spaces[0].id
    if old.session.selectedSpace.selectedFavoriteID == nil,
      let selected = old.session.selectedSpace.selectedTabID,
      let destination = spaces.firstIndex(where: { $0.tabs.contains { $0.id == selected } })
    {
      selectedSpace = spaces[destination].id
      spaces[destination].selectedTabID = selected
    }
    if let removedSelectedPage,
      let destination = spaces.firstIndex(where: {
        $0.profileID == removedSelectedPage.profileID
          && $0.tabs.contains(where: { $0.id == removedSelectedPage.tab.id })
      })
    {
      selectedSpace = spaces[destination].id
    }
    var session = try BrowserSession(
      profiles: catalog.profiles, spaces: spaces, selectedSpaceID: selectedSpace,
      favorites: catalog.favorites, favoritePages: favoritePages)
    session.closedTabs = old.session.closedTabs.filter { entry in
      spaces.contains { $0.id == entry.spaceID && $0.profileID == entry.profileID }
    }
    return WorkspaceWindow(id: old.id, session: session, pins: references, geometry: old.geometry)
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
    space.splits = []
    space.selectedTabID = nil
    space.selectedFavoriteID = nil
    space.folders = source.folders.map(sharedFolder)
    return space
  }

  private static func tabProfiles(_ session: BrowserSession) -> [UUID: UUID] {
    let favoriteProfiles = Dictionary(
      uniqueKeysWithValues: session.favorites.map { ($0.id, $0.profileID) })
    return Dictionary(
      uniqueKeysWithValues: session.spaces.flatMap { space in
        space.tabs.map { ($0.id, space.profileID) }
      }
        + session.closedTabs.map { ($0.id, $0.profileID) }
    )
    .merging(
      Dictionary(
        uniqueKeysWithValues: session.favoritePages.compactMap { page in
          favoriteProfiles[page.favoriteID].map { (page.tab.id, $0) }
        }), uniquingKeysWith: { first, _ in first })
  }
}
