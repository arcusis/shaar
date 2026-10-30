import Foundation

public struct BrowserFolder: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var parentID: UUID?
  public var isCollapsed: Bool
  public var isPinned: Bool

  public init(
    id: UUID = UUID(), name: String, parentID: UUID? = nil, isCollapsed: Bool = false,
    isPinned: Bool = true
  ) {
    self.id = id
    self.name = name
    self.parentID = parentID
    self.isCollapsed = isCollapsed
    self.isPinned = isPinned
  }

  private enum CodingKeys: String, CodingKey { case id, name, parentID, isCollapsed, isPinned }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
    isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? true
  }
}

public enum PinnedSidebarItem: Identifiable, Equatable, Sendable {
  case folder(BrowserFolder, depth: Int)
  case tab(BrowserTab, depth: Int)

  public var id: String {
    switch self {
    case .folder(let folder, _): "folder-\(folder.id)"
    case .tab(let tab, _): "tab-\(tab.id)"
    }
  }
}

private enum FolderWalk {
  case folder(BrowserFolder, Int)
  case tabs(UUID, Int)
}

extension BrowserSpace {
  /// Iterative traversal keeps malformed or deeply nested data from recursing indefinitely.
  public func pinnedItems(includingCollapsed: Bool = false) -> [PinnedSidebarItem] {
    items(isPinned: true, includingCollapsed: includingCollapsed)
  }

  public func items(isPinned: Bool, includingCollapsed: Bool = false) -> [PinnedSidebarItem] {
    var result = tabs.filter { $0.isPinned == isPinned && $0.folderID == nil }.map {
      PinnedSidebarItem.tab($0, depth: 0)
    }
    var children: [UUID: [BrowserFolder]] = [:]
    var members: [UUID: [BrowserTab]] = [:]
    let sectionFolders = folders.filter { $0.isPinned == isPinned }
    for folder in sectionFolders {
      if let parent = folder.parentID { children[parent, default: []].append(folder) }
    }
    for tab in tabs where tab.isPinned == isPinned {
      if let folder = tab.folderID { members[folder, default: []].append(tab) }
    }
    var stack: [FolderWalk] = sectionFolders.filter { $0.parentID == nil }.reversed().map {
      .folder($0, 0)
    }
    var visited: Set<UUID> = []
    while let item = stack.popLast() {
      switch item {
      case .folder(let folder, let depth):
        guard visited.insert(folder.id).inserted else { continue }
        result.append(.folder(folder, depth: depth))
        if includingCollapsed || !folder.isCollapsed {
          stack.append(.tabs(folder.id, depth + 1))
          for child in (children[folder.id] ?? []).reversed() {
            stack.append(.folder(child, depth + 1))
          }
        }
      case .tabs(let folder, let depth):
        result += (members[folder] ?? []).map { .tab($0, depth: depth) }
      }
    }
    return result
  }

  /// Hidden folder contents retain their logical/native order and live documents.
  public var orderedTabs: [BrowserTab] {
    (items(isPinned: true, includingCollapsed: true)
      + items(isPinned: false, includingCollapsed: true)).compactMap {
        if case .tab(let tab, _) = $0 { return tab }
        return nil
      }
  }

  public func folderPath(to id: UUID?) -> [BrowserFolder] {
    let lookup = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var path: [BrowserFolder] = []
    var next = id
    var visited: Set<UUID> = []
    while let current = next, let folder = lookup[current], visited.insert(current).inserted {
      path.append(folder)
      next = folder.parentID
    }
    return path
  }

  func subtreeIDs(_ id: UUID) -> Set<UUID> {
    guard folders.contains(where: { $0.id == id }) else { return [] }
    var children: [UUID: [UUID]] = [:]
    for folder in folders {
      if let parent = folder.parentID { children[parent, default: []].append(folder.id) }
    }
    var result: Set<UUID> = []
    var stack = [id]
    while let current = stack.popLast() {
      if result.insert(current).inserted { stack += children[current] ?? [] }
    }
    return result
  }

  mutating func normalizeFolders() {
    let pinned = items(isPinned: true, includingCollapsed: true).compactMap {
      if case .folder(let folder, _) = $0 { return folder }
      return nil
    }
    let today = items(isPinned: false, includingCollapsed: true).compactMap {
      if case .folder(let folder, _) = $0 { return folder }
      return nil
    }
    folders = pinned + today
  }

  mutating func expandFolderPath(_ id: UUID?) {
    let ids = Set(folderPath(to: id).map(\.id))
    for index in folders.indices where ids.contains(folders[index].id) {
      folders[index].isCollapsed = false
    }
  }
}
