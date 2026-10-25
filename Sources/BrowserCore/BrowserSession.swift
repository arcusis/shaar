import Foundation

public struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String

  public init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
}

public enum SpaceTint: String, Codable, CaseIterable, Sendable {
  case lavender, ocean, rose, forest
}

public struct BrowserTab: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var url: URL
  public var title: String
  public var isPinned: Bool
  public var folderID: UUID?

  public init(
    id: UUID = UUID(), url: URL, title: String? = nil, isPinned: Bool = false, folderID: UUID? = nil
  ) {
    self.id = id
    self.url = url
    self.title = title ?? url.host() ?? url.absoluteString
    self.isPinned = isPinned
    self.folderID = folderID
  }
}

public struct BrowserSpace: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let profileID: UUID
  public var name: String
  public var symbol: String
  public var tint: SpaceTint
  public var tabs: [BrowserTab]
  public var selectedTabID: UUID?
  public var folders: [BrowserFolder]

  public init(
    id: UUID = UUID(), profileID: UUID, name: String, symbol: String,
    tint: SpaceTint, tabs: [BrowserTab] = [], selectedTabID: UUID? = nil,
    folders: [BrowserFolder] = []
  ) {
    self.id = id
    self.profileID = profileID
    self.name = name
    self.symbol = symbol
    self.tint = tint
    self.tabs = tabs
    self.selectedTabID = selectedTabID ?? tabs.first?.id
    self.folders = folders
  }

  public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
}

public enum SessionError: Error, LocalizedError, Equatable {
  case unsupportedVersion, invalidState

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion: "This session was saved by an unsupported browser version."
    case .invalidState: "The saved session contains invalid spaces, profiles, or tabs."
    }
  }
}

public struct BrowserSession: Codable, Equatable, Sendable {
  public static let currentVersion = 3
  public let version: Int
  public private(set) var profiles: [BrowserProfile]
  public internal(set) var spaces: [BrowserSpace]
  public internal(set) var selectedSpaceID: UUID
  public internal(set) var closedTabs: [ClosedBrowserTab]

  public init(profiles: [BrowserProfile], spaces: [BrowserSpace], selectedSpaceID: UUID) throws {
    self.version = Self.currentVersion
    self.profiles = profiles
    self.spaces = spaces
    self.selectedSpaceID = selectedSpaceID
    closedTabs = []
    try validate()
  }

  private enum CodingKeys: String, CodingKey {
    case version, profiles, spaces, selectedSpaceID, closedTabs
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let sourceVersion = try values.decode(Int.self, forKey: .version)
    guard [1, 2, 3].contains(sourceVersion) else { throw SessionError.unsupportedVersion }
    version = Self.currentVersion
    profiles = try values.decode([BrowserProfile].self, forKey: .profiles)
    spaces =
      sourceVersion == 1
      ? try values.decode([LegacySpace].self, forKey: .spaces).map(\.value)
      : try values.decode([BrowserSpace].self, forKey: .spaces)
    selectedSpaceID = try values.decode(UUID.self, forKey: .selectedSpaceID)
    if sourceVersion == Self.currentVersion {
      closedTabs = try values.decode([ClosedBrowserTab].self, forKey: .closedTabs)
    } else {
      guard
        try values.decodeIfPresent([ClosedBrowserTab].self, forKey: .closedTabs)?.isEmpty != false
      else { throw SessionError.invalidState }
      closedTabs = []
    }
    try validate()
  }

  public var selectedSpace: BrowserSpace { spaces.first { $0.id == selectedSpaceID }! }

  public static func fresh() -> BrowserSession {
    let personal = BrowserProfile(name: "Personal")
    let work = BrowserProfile(name: "Work")
    let spaces = [
      BrowserSpace(profileID: personal.id, name: "Personal", symbol: "house", tint: .lavender),
      BrowserSpace(profileID: work.id, name: "Work", symbol: "briefcase", tint: .ocean),
    ]
    // These values are constructed together and satisfy the session invariants.
    return try! BrowserSession(
      profiles: [personal, work], spaces: spaces, selectedSpaceID: spaces[0].id)
  }

  public func validate() throws {
    guard version == Self.currentVersion else { throw SessionError.unsupportedVersion }
    let profileIDs = Set(profiles.map(\.id))
    let spaceIDs = Set(spaces.map(\.id))
    let tabIDs = spaces.flatMap { $0.tabs.map(\.id) }
    let folderIDs = spaces.flatMap { $0.folders.map(\.id) }
    let closedIDs = closedTabs.map(\.id)
    guard !profiles.isEmpty, !spaces.isEmpty,
      profileIDs.count == profiles.count,
      spaceIDs.count == spaces.count,
      Set(tabIDs).count == tabIDs.count,
      Set(folderIDs).count == folderIDs.count,
      Set(closedIDs).count == closedIDs.count,
      Set(closedIDs).isDisjoint(with: tabIDs),
      spaceIDs.contains(selectedSpaceID),
      profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
      spaces.allSatisfy({ space in
        profileIDs.contains(space.profileID)
          && !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && (space.selectedTabID == nil || space.tabs.contains { $0.id == space.selectedTabID })
          && space.tabs.allSatisfy { Self.isPersistableURL($0.url) }
      })
    else { throw SessionError.invalidState }
    let spacesByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
    let closedCounts = Dictionary(grouping: closedTabs, by: \.spaceID)
    guard closedCounts.values.allSatisfy({ $0.count <= Self.closedTabLimitPerSpace }),
      closedTabs.allSatisfy({ entry in
        spacesByID[entry.spaceID]?.profileID == entry.profileID && entry.index >= 0
          && Self.isPersistableURL(entry.tab.url)
          && (entry.tab.folderID == nil || entry.tab.isPinned)
      })
    else { throw SessionError.invalidState }
    for space in spaces {
      let localIDs = Set(space.folders.map(\.id))
      guard
        space.folders.allSatisfy({
          !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ($0.parentID == nil || localIDs.contains($0.parentID!))
        }),
        space.tabs.allSatisfy({
          $0.folderID == nil || ($0.isPinned && localIDs.contains($0.folderID!))
        }),
        space.pinnedItems(includingCollapsed: true).filter({
          if case .folder = $0 { return true }
          return false
        }).count == space.folders.count
      else { throw SessionError.invalidState }
    }
  }

  public mutating func selectSpace(_ id: UUID) {
    guard spaces.contains(where: { $0.id == id }) else { return }
    selectedSpaceID = id
  }

  public mutating func cycleSpace(by offset: Int) {
    guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return }
    let next = ((index + offset) % spaces.count + spaces.count) % spaces.count
    selectedSpaceID = spaces[next].id
  }

  @discardableResult
  public mutating func moveSpace(_ id: UUID, before targetID: UUID?) -> Bool {
    guard id != targetID, let source = spaces.firstIndex(where: { $0.id == id }),
      targetID == nil || spaces.contains(where: { $0.id == targetID })
    else { return false }
    var reordered = spaces
    let space = reordered.remove(at: source)
    let destination = reordered.firstIndex { $0.id == targetID } ?? reordered.endIndex
    reordered.insert(space, at: destination)
    guard reordered != spaces else { return false }
    spaces = reordered
    return true
  }

  /// Moving a live tab never changes its engine profile or document identity.
  @discardableResult
  public mutating func moveTab(
    _ id: UUID, from sourceID: UUID, to destinationID: UUID,
    before targetID: UUID? = nil, pinned: Bool? = nil, folderID: UUID? = nil
  ) -> Bool {
    guard id != targetID, let source = spaces.firstIndex(where: { $0.id == sourceID }),
      let destination = spaces.firstIndex(where: { $0.id == destinationID }),
      spaces[source].profileID == spaces[destination].profileID,
      let position = spaces[source].tabs.firstIndex(where: { $0.id == id })
    else { return false }
    var tab = spaces[source].tabs[position]
    if let folderID {
      guard pinned != false, spaces[destination].folders.contains(where: { $0.id == folderID })
      else { return false }
      tab.folderID = folderID
      tab.isPinned = true
    } else if source != destination || pinned != nil {
      tab.folderID = nil
      tab.isPinned = pinned ?? tab.isPinned
    }
    if let targetID {
      guard let target = spaces[destination].tabs.first(where: { $0.id == targetID }),
        target.isPinned == tab.isPinned, target.folderID == tab.folderID
      else { return false }
    }
    let followsSelection = sourceID == selectedSpaceID && spaces[source].selectedTabID == id
    var updated = spaces
    updated[source].tabs.remove(at: position)
    let tabs = updated[destination].tabs
    let insertion =
      targetID.flatMap { target in tabs.firstIndex { $0.id == target } }
      ?? tabs.lastIndex(where: { $0.isPinned == tab.isPinned && $0.folderID == tab.folderID }).map {
        $0 + 1
      }
      ?? (tab.isPinned ? tabs.startIndex : tabs.endIndex)
    updated[destination].tabs.insert(tab, at: insertion)
    updated[destination].expandFolderPath(tab.folderID)
    if source != destination {
      if updated[source].selectedTabID == id {
        let remaining = updated[source].tabs
        updated[source].selectedTabID =
          remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
      }
      if followsSelection || updated[destination].selectedTabID == nil {
        updated[destination].selectedTabID = id
      }
    }
    guard updated != spaces else { return false }
    spaces = updated
    if followsSelection { selectedSpaceID = destinationID }
    return true
  }

  @discardableResult
  public mutating func addSpace(
    name: String, sharingProfile profileID: UUID? = nil, tint: SpaceTint? = nil
  ) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    let profile: BrowserProfile
    if let profileID {
      guard let existing = profiles.first(where: { $0.id == profileID }) else { return nil }
      profile = existing
    } else {
      profile = BrowserProfile(name: name)
      profiles.append(profile)
    }
    let color = tint ?? SpaceTint.allCases[spaces.count % SpaceTint.allCases.count]
    let space = BrowserSpace(profileID: profile.id, name: name, symbol: "square.stack", tint: color)
    spaces.append(space)
    selectedSpaceID = space.id
    return space.id
  }

  @discardableResult
  public mutating func updateSpace(_ id: UUID, name: String, tint: SpaceTint) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else {
      return false
    }
    spaces[index].name = name
    spaces[index].tint = tint
    return true
  }

  @discardableResult
  public mutating func removeSpace(_ id: UUID) -> Bool {
    guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else {
      return false
    }
    spaces.remove(at: index)
    closedTabs.removeAll { $0.spaceID == id }
    if selectedSpaceID == id {
      selectedSpaceID = spaces[min(index, spaces.count - 1)].id
    }
    // Removing a space must not delete a profile or its future engine-owned data.
    return true
  }

  @discardableResult
  public mutating func open(_ url: URL) -> UUID? {
    guard NavigationInput.isWebURL(url),
      let index = spaces.firstIndex(where: { $0.id == selectedSpaceID })
    else { return nil }
    let tab = BrowserTab(url: url)
    spaces[index].tabs.append(tab)
    spaces[index].selectedTabID = tab.id
    return tab.id
  }

  public mutating func selectTab(_ tabID: UUID, in spaceID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      spaces[index].tabs.contains(where: { $0.id == tabID })
    else { return }
    selectedSpaceID = spaceID
    spaces[index].selectedTabID = tabID
    spaces[index].expandFolderPath(spaces[index].tabs.first { $0.id == tabID }?.folderID)
  }

  public mutating func closeTab(_ tabID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
      let tabIndex = spaces[index].tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    closedTabs.append(
      ClosedBrowserTab(
        tab: spaces[index].tabs[tabIndex], spaceID: spaces[index].id,
        profileID: spaces[index].profileID, index: tabIndex))
    if closedTabs.filter({ $0.spaceID == spaces[index].id }).count > Self.closedTabLimitPerSpace,
      let oldest = closedTabs.firstIndex(where: { $0.spaceID == spaces[index].id })
    {
      closedTabs.remove(at: oldest)
    }
    spaces[index].tabs.remove(at: tabIndex)
    if spaces[index].selectedTabID == tabID {
      let tabs = spaces[index].tabs
      spaces[index].selectedTabID = tabs.isEmpty ? nil : tabs[min(tabIndex, tabs.count - 1)].id
    }
  }

  /// Native navigation changes metadata, never the immutable space/profile assignment.
  @discardableResult
  public mutating func updateTab(_ id: UUID, url: URL, title: String) -> Bool {
    guard Self.isPersistableURL(url),
      let space = spaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
      let tab = spaces[space].tabs.firstIndex(where: { $0.id == id })
    else { return false }
    let title = title.isEmpty ? url.host() ?? url.absoluteString : title
    guard spaces[space].tabs[tab].url != url || spaces[space].tabs[tab].title != title else {
      return false
    }
    spaces[space].tabs[tab].url = url
    spaces[space].tabs[tab].title = title
    return true
  }

  /// Popups and links inherit their engine profile. Unknown profiles are never reassigned.
  @discardableResult
  public mutating func insertNativeTab(
    _ tab: BrowserTab, profileID: UUID, openerID: UUID?, foreground: Bool
  ) -> UUID? {
    guard Self.isPersistableURL(tab.url),
      !closedTabs.contains(where: { $0.id == tab.id }),
      !spaces.contains(where: { $0.tabs.contains { $0.id == tab.id } })
    else { return nil }
    let openerSpace = spaces.firstIndex {
      $0.profileID == profileID && $0.tabs.contains { $0.id == openerID }
    }
    let currentSpace = spaces.firstIndex { $0.id == selectedSpaceID && $0.profileID == profileID }
    guard
      let index = openerSpace ?? currentSpace
        ?? spaces.firstIndex(where: { $0.profileID == profileID })
    else { return nil }
    spaces[index].tabs.append(tab)
    if foreground {
      selectedSpaceID = spaces[index].id
      spaces[index].selectedTabID = tab.id
    }
    return spaces[index].id
  }

  private static func isPersistableURL(_ url: URL) -> Bool {
    NavigationInput.isWebURL(url) || url.absoluteString == "about:blank"
  }

  public mutating func togglePin(_ tabID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
      let tabIndex = spaces[index].tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let space = spaces[index]
    moveTab(tabID, from: space.id, to: space.id, pinned: !space.tabs[tabIndex].isPinned)
  }
}
