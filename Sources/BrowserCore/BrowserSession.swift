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

  public init(id: UUID = UUID(), url: URL, title: String? = nil, isPinned: Bool = false) {
    self.id = id
    self.url = url
    self.title = title ?? url.host() ?? url.absoluteString
    self.isPinned = isPinned
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

  public init(
    id: UUID = UUID(), profileID: UUID, name: String, symbol: String,
    tint: SpaceTint, tabs: [BrowserTab] = [], selectedTabID: UUID? = nil
  ) {
    self.id = id
    self.profileID = profileID
    self.name = name
    self.symbol = symbol
    self.tint = tint
    self.tabs = tabs
    self.selectedTabID = selectedTabID ?? tabs.first?.id
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
  public let version: Int
  public private(set) var profiles: [BrowserProfile]
  public private(set) var spaces: [BrowserSpace]
  public private(set) var selectedSpaceID: UUID

  public init(profiles: [BrowserProfile], spaces: [BrowserSpace], selectedSpaceID: UUID) throws {
    self.version = 1
    self.profiles = profiles
    self.spaces = spaces
    self.selectedSpaceID = selectedSpaceID
    try validate()
  }

  private enum CodingKeys: String, CodingKey {
    case version, profiles, spaces, selectedSpaceID
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    profiles = try values.decode([BrowserProfile].self, forKey: .profiles)
    spaces = try values.decode([BrowserSpace].self, forKey: .spaces)
    selectedSpaceID = try values.decode(UUID.self, forKey: .selectedSpaceID)
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
    guard version == 1 else { throw SessionError.unsupportedVersion }
    let profileIDs = Set(profiles.map(\.id))
    let spaceIDs = Set(spaces.map(\.id))
    let tabIDs = spaces.flatMap { $0.tabs.map(\.id) }
    guard !profiles.isEmpty, !spaces.isEmpty,
      profileIDs.count == profiles.count,
      spaceIDs.count == spaces.count,
      Set(tabIDs).count == tabIDs.count,
      spaceIDs.contains(selectedSpaceID),
      profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
      spaces.allSatisfy({ space in
        profileIDs.contains(space.profileID)
          && !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && (space.selectedTabID == nil || space.tabs.contains { $0.id == space.selectedTabID })
          && space.tabs.allSatisfy { NavigationInput.isWebURL($0.url) }
      })
    else { throw SessionError.invalidState }
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
  }

  public mutating func closeTab(_ tabID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
      let tabIndex = spaces[index].tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    spaces[index].tabs.remove(at: tabIndex)
    if spaces[index].selectedTabID == tabID {
      let tabs = spaces[index].tabs
      spaces[index].selectedTabID = tabs.isEmpty ? nil : tabs[min(tabIndex, tabs.count - 1)].id
    }
  }

  public mutating func togglePin(_ tabID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
      let tabIndex = spaces[index].tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    spaces[index].tabs[tabIndex].isPinned.toggle()
  }
}
