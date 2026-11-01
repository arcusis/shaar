// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public struct BrowserProfile: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var tint: SpaceTint?
  public var customRGB: SpaceRGBColor?
  /// SF Symbol shown for the profile; nil uses the default person glyph.
  public var symbol: String?

  public init(
    id: UUID = UUID(), name: String, tint: SpaceTint? = nil, customRGB: SpaceRGBColor? = nil,
    symbol: String? = nil
  ) {
    self.id = id
    self.name = name
    self.tint = tint
    self.customRGB = customRGB
    self.symbol = symbol
  }

  private enum CodingKeys: String, CodingKey { case id, name, tint, customRGB, symbol }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    tint = try values.decodeIfPresent(SpaceTint.self, forKey: .tint)
    customRGB = try values.decodeIfPresent(SpaceRGBColor.self, forKey: .customRGB)
    symbol = try values.decodeIfPresent(String.self, forKey: .symbol)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(name, forKey: .name)
    try values.encodeIfPresent(tint, forKey: .tint)
    try values.encodeIfPresent(customRGB, forKey: .customRGB)
    try values.encodeIfPresent(symbol, forKey: .symbol)
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

public struct BrowserSplit: Codable, Identifiable, Equatable, Sendable {
  /// Arc's limit: up to four tabs in one split.
  public static let maxPanes = 4

  public let id: UUID
  public internal(set) var root: SplitNode
  public var tabIDs: [UUID] { root.paneIDs }

  public init(id: UUID = UUID(), root: SplitNode) {
    self.id = id
    self.root = root
  }

  public init(id: UUID = UUID(), tabIDs: [UUID], ratio: Double = 0.5) {
    let weights = tabIDs.count == 2 ? [ratio, 1 - ratio] : nil
    let panes = tabIDs.map(SplitNode.pane)
    self.init(
      id: id,
      root: weights.map { .group(.columns, panes, $0) } ?? .evenly(.columns, panes))
  }

  private enum CodingKeys: String, CodingKey {
    case id, root, tabIDs, ratio
  }

  /// Older sessions stored two side-by-side tabs and a divider ratio.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let id = try c.decode(UUID.self, forKey: .id)
    if let root = try c.decodeIfPresent(SplitNode.self, forKey: .root) {
      self.init(id: id, root: root)
    } else {
      self.init(
        id: id, tabIDs: try c.decode([UUID].self, forKey: .tabIDs),
        ratio: try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(root, forKey: .root)
  }

  var isValid: Bool {
    (2...Self.maxPanes).contains(tabIDs.count) && root.isValid
  }
}

public struct BrowserSpace: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public internal(set) var profileID: UUID
  public var name: String
  public var symbol: String
  public var tint: SpaceTint
  public var customRGB: SpaceRGBColor?
  public var tabs: [BrowserTab]
  public var selectedTabID: UUID?
  public var selectedFavoriteID: UUID?
  public var folders: [BrowserFolder]
  public var splits: [BrowserSplit]

  public init(
    id: UUID = UUID(), profileID: UUID, name: String, symbol: String,
    tint: SpaceTint, customRGB: SpaceRGBColor? = nil, tabs: [BrowserTab] = [],
    selectedTabID: UUID? = nil, selectedFavoriteID: UUID? = nil,
    folders: [BrowserFolder] = [], splits: [BrowserSplit] = []
  ) {
    self.id = id
    self.profileID = profileID
    self.name = name
    self.symbol = symbol
    self.tint = tint
    self.customRGB = customRGB
    self.tabs = tabs
    self.selectedTabID = selectedTabID ?? tabs.first?.id
    self.selectedFavoriteID = selectedFavoriteID
    self.folders = folders
    self.splits = splits
  }

  private enum CodingKeys: String, CodingKey {
    case id, profileID, name, symbol, tint, customRGB, tabs, selectedTabID, selectedFavoriteID,
      folders, splits
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    profileID = try c.decode(UUID.self, forKey: .profileID)
    name = try c.decode(String.self, forKey: .name)
    symbol = try c.decode(String.self, forKey: .symbol)
    tint = try c.decode(SpaceTint.self, forKey: .tint)
    customRGB = try c.decodeIfPresent(SpaceRGBColor.self, forKey: .customRGB)
    tabs = try c.decode([BrowserTab].self, forKey: .tabs)
    selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
    selectedFavoriteID = try c.decodeIfPresent(UUID.self, forKey: .selectedFavoriteID)
    folders = try c.decode([BrowserFolder].self, forKey: .folders)
    splits = try c.decodeIfPresent([BrowserSplit].self, forKey: .splits) ?? []
  }

  public mutating func reconcileSplits() {
    let ids = Set(tabs.map(\.id))
    splits = splits.compactMap { split in
      var root: SplitNode? = split.root
      for id in split.tabIDs where !ids.contains(id) { root = root?.removing(id) }
      guard let root, root.paneIDs.count >= 2 else { return nil }
      return BrowserSplit(id: split.id, root: root)
    }
  }

  public var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
}

public enum SessionError: Error, LocalizedError, Equatable {
  case unsupportedVersion, invalidState

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion:
      BrowserLocalization.string("This session was saved by an unsupported browser version.")
    case .invalidState:
      BrowserLocalization.string("The saved session contains invalid spaces, profiles, or tabs.")
    }
  }
}

public struct BrowserSession: Codable, Equatable, Sendable {
  public static let currentVersion = 4
  public let version: Int
  public private(set) var profiles: [BrowserProfile]
  public internal(set) var spaces: [BrowserSpace]
  public internal(set) var selectedSpaceID: UUID
  public internal(set) var closedTabs: [ClosedBrowserTab]
  public internal(set) var favorites: [BrowserFavorite]
  public internal(set) var favoritePages: [BrowserFavoritePage]

  public init(
    profiles: [BrowserProfile], spaces: [BrowserSpace], selectedSpaceID: UUID,
    favorites: [BrowserFavorite] = [], favoritePages: [BrowserFavoritePage] = []
  ) throws {
    self.version = Self.currentVersion
    self.profiles = profiles
    self.spaces = spaces
    self.selectedSpaceID = selectedSpaceID
    closedTabs = []
    self.favorites = favorites
    self.favoritePages = favoritePages
    try validate()
  }

  private enum CodingKeys: String, CodingKey {
    case version, profiles, spaces, selectedSpaceID, closedTabs, favorites, favoritePages
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let sourceVersion = try values.decode(Int.self, forKey: .version)
    guard [1, 2, 3, 4].contains(sourceVersion) else { throw SessionError.unsupportedVersion }
    version = Self.currentVersion
    profiles = try values.decode([BrowserProfile].self, forKey: .profiles)
    spaces =
      sourceVersion == 1
      ? try values.decode([LegacySpace].self, forKey: .spaces).map(\.value)
      : try values.decode([BrowserSpace].self, forKey: .spaces)
    selectedSpaceID = try values.decode(UUID.self, forKey: .selectedSpaceID)
    if sourceVersion >= 3 {
      closedTabs = try values.decode([ClosedBrowserTab].self, forKey: .closedTabs)
    } else {
      guard
        try values.decodeIfPresent([ClosedBrowserTab].self, forKey: .closedTabs)?.isEmpty != false
      else { throw SessionError.invalidState }
      closedTabs = []
    }
    if sourceVersion == Self.currentVersion {
      favorites = try values.decode([BrowserFavorite].self, forKey: .favorites)
      favoritePages = try values.decode([BrowserFavoritePage].self, forKey: .favoritePages)
    } else {
      guard
        try values.decodeIfPresent([BrowserFavorite].self, forKey: .favorites)?.isEmpty != false,
        try values.decodeIfPresent([BrowserFavoritePage].self, forKey: .favoritePages)?.isEmpty
          != false
      else { throw SessionError.invalidState }
      favorites = []
      favoritePages = []
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
    let favoriteIDs = favorites.map(\.id)
    let favoritePageIDs = favoritePages.map(\.tab.id)
    let favoritePageFavoriteIDs = favoritePages.map(\.favoriteID)
    guard !profiles.isEmpty, !spaces.isEmpty,
      profileIDs.count == profiles.count,
      spaceIDs.count == spaces.count,
      Set(tabIDs).count == tabIDs.count,
      Set(folderIDs).count == folderIDs.count,
      Set(closedIDs).count == closedIDs.count,
      Set(closedIDs).isDisjoint(with: tabIDs + favoritePageIDs),
      Set(tabIDs).isDisjoint(with: favoritePageIDs),
      Set(favoritePageIDs).count == favoritePageIDs.count,
      Set(favoriteIDs).count == favoriteIDs.count,
      Set(favoritePageFavoriteIDs).count == favoritePageFavoriteIDs.count,
      spaceIDs.contains(selectedSpaceID),
      profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
      spaces.allSatisfy({ space in
        profileIDs.contains(space.profileID)
          && !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && (space.selectedTabID == nil || space.tabs.contains { $0.id == space.selectedTabID })
          && space.tabs.allSatisfy { Self.isPersistableURL($0.url) }
      })
    else { throw SessionError.invalidState }
    let favoritesByID = Dictionary(uniqueKeysWithValues: favorites.map { ($0.id, $0) })
    guard
      favorites.allSatisfy({ favorite in
        profileIDs.contains(favorite.profileID) && Self.isPersistableURL(favorite.originalURL)
          && !favorite.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }), Set(favoritePageFavoriteIDs).isSubset(of: Set(favoriteIDs)),
      favoritePages.allSatisfy({ page in
        guard let favorite = favoritesByID[page.favoriteID] else { return false }
        return page.tab.isPinned == false && page.tab.folderID == nil
          && Self.isPersistableURL(page.tab.url)
          && !page.tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && spaces.contains(where: { $0.profileID == favorite.profileID })
      }),
      spaces.allSatisfy({ space in
        space.selectedFavoriteID.map { id in
          favoritesByID[id]?.profileID == space.profileID
            && favoritePageFavoriteIDs.contains(id)
        } ?? true
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
      let splitIDs = space.splits.flatMap(\.tabIDs)
      guard Set(splitIDs).count == splitIDs.count,
        Set(space.splits.map(\.id)).count == space.splits.count,
        space.splits.allSatisfy(\.isValid),
        Set(splitIDs).isSubset(of: Set(space.tabs.map(\.id)))
      else { throw SessionError.invalidState }
      guard
        space.folders.allSatisfy({ folder in
          !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (folder.parentID == nil
              || space.folders.contains(where: {
                $0.id == folder.parentID && $0.isPinned == folder.isPinned
              }))
        }),
        space.tabs.allSatisfy({ tab in
          tab.folderID == nil
            || space.folders.contains(where: {
              $0.id == tab.folderID && $0.isPinned == tab.isPinned
            })
        }),
        (space.items(isPinned: true, includingCollapsed: true)
          + space.items(isPinned: false, includingCollapsed: true)).filter({
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
      guard let folder = spaces[destination].folders.first(where: { $0.id == folderID }),
        pinned == nil || pinned == folder.isPinned
      else { return false }
      tab.folderID = folderID
      tab.isPinned = folder.isPinned
    } else if source != destination || pinned != nil {
      tab.folderID = nil
      tab.isPinned = pinned ?? tab.isPinned
    }
    if let targetID {
      guard let target = spaces[destination].tabs.first(where: { $0.id == targetID }),
        target.isPinned == tab.isPinned, target.folderID == tab.folderID
      else { return false }
    }
    let followsSelection =
      sourceID == selectedSpaceID
      && spaces[source].selectedFavoriteID == nil && spaces[source].selectedTabID == id
    var updated = spaces
    updated[source].tabs.remove(at: position)
    if source != destination { updated[source].reconcileSplits() }
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
      if followsSelection { updated[destination].selectedFavoriteID = nil }
    }
    guard updated != spaces else { return false }
    spaces = updated
    if followsSelection { selectedSpaceID = destinationID }
    return true
  }

  @discardableResult
  public mutating func addSpace(
    name: String, sharingProfile profileID: UUID? = nil, tint: SpaceTint? = nil,
    customRGB: SpaceRGBColor? = nil
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
    let space = BrowserSpace(
      profileID: profile.id, name: name, symbol: "square.stack", tint: color,
      customRGB: customRGB)
    spaces.append(space)
    selectedSpaceID = space.id
    return space.id
  }

  @discardableResult
  public mutating func updateSpace(
    _ id: UUID, name: String, tint: SpaceTint, customRGB: SpaceRGBColor? = nil
  ) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = spaces.firstIndex(where: { $0.id == id }) else {
      return false
    }
    spaces[index].name = name
    spaces[index].tint = tint
    spaces[index].customRGB = customRGB
    return true
  }

  @discardableResult
  public mutating func createProfile(name: String) -> UUID? {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else { return nil }
    let profile = BrowserProfile(name: cleanName)
    profiles.append(profile)
    return profile.id
  }

  /// Explicitly reassign a Space; profile-owned Favorites stay with their original profile.
  @discardableResult
  public mutating func setSpaceProfile(_ id: UUID, to profileID: UUID) -> Bool {
    guard profiles.contains(where: { $0.id == profileID }),
      let index = spaces.firstIndex(where: { $0.id == id })
    else { return false }
    let oldProfile = spaces[index].profileID
    guard oldProfile != profileID else { return true }
    spaces[index].profileID = profileID
    spaces[index].selectedFavoriteID = nil
    closedTabs.removeAll { $0.spaceID == id }
    if !spaces.contains(where: { $0.profileID == oldProfile }) {
      let oldFavorites = Set(favorites.filter { $0.profileID == oldProfile }.map(\.id))
      favoritePages.removeAll { oldFavorites.contains($0.favoriteID) }
    }
    return true
  }

  @discardableResult
  public mutating func removeSpace(_ id: UUID) -> Bool {
    guard let index = spaces.firstIndex(where: { $0.id == id }), spaces.count > 1 else {
      return false
    }
    let profileID = spaces[index].profileID
    if spaces.filter({ $0.profileID == profileID }).count == 1,
      favoritePages.contains(where: { page in
        favorites.first(where: { $0.id == page.favoriteID })?.profileID == profileID
      })
    {
      return false
    }
    return removeSpace(id, favoriteDisposition: .closePage)
  }

  @discardableResult
  public mutating func removeSpace(
    _ id: UUID, favoriteDisposition: FavoritePageDisposition
  ) -> Bool {
    guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else {
      return false
    }
    let profileID = spaces[index].profileID
    let lastProfileSpace = spaces.filter { $0.profileID == profileID }.count == 1
    if lastProfileSpace {
      let ownedPages = favoritePages.filter { page in
        favorites.first(where: { $0.id == page.favoriteID })?.profileID == profileID
      }
      if !ownedPages.isEmpty {
        switch favoriteDisposition {
        case .closePage:
          favoritePages.removeAll { page in
            favorites.first(where: { $0.id == page.favoriteID })?.profileID == profileID
          }
        case .preserveAsTab:
          return false
        }
        for spaceIndex in spaces.indices where spaces[spaceIndex].profileID == profileID {
          spaces[spaceIndex].selectedFavoriteID = nil
        }
      }
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
    spaces[index].selectedFavoriteID = nil
    return tab.id
  }

  public mutating func selectTab(_ tabID: UUID, in spaceID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      spaces[index].tabs.contains(where: { $0.id == tabID })
    else { return }
    selectedSpaceID = spaceID
    spaces[index].selectedTabID = tabID
    spaces[index].selectedFavoriteID = nil
    spaces[index].expandFolderPath(spaces[index].tabs.first { $0.id == tabID }?.folderID)
  }

  public mutating func closeTab(_ tabID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
      let tabIndex = spaces[index].tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let splitPeer = spaces[index].splits.first { $0.tabIDs.contains(tabID) }?.tabIDs.first {
      $0 != tabID
    }
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
    spaces[index].reconcileSplits()
    if spaces[index].selectedTabID == tabID {
      let tabs = spaces[index].tabs
      spaces[index].selectedTabID =
        splitPeer ?? (tabs.isEmpty ? nil : tabs[min(tabIndex, tabs.count - 1)].id)
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
      !spaces.contains(where: { $0.tabs.contains { $0.id == tab.id } }),
      !favoritePages.contains(where: { $0.tab.id == tab.id })
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
      spaces[index].selectedFavoriteID = nil
    }
    return spaces[index].id
  }

  static func isPersistableURL(_ url: URL) -> Bool {
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
