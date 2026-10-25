import Foundation

/// A recovery snapshot, not a suspended document or reusable engine tab identity.
public struct ClosedBrowserTab: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { tab.id }
  public let tab: BrowserTab
  public let spaceID: UUID
  public let profileID: UUID
  public let index: Int

  public init(tab: BrowserTab, spaceID: UUID, profileID: UUID, index: Int) {
    self.tab = tab
    self.spaceID = spaceID
    self.profileID = profileID
    self.index = index
  }
}

extension BrowserSession {
  public static let closedTabLimitPerSpace = 25

  public func recentlyClosedTabs(in spaceID: UUID) -> [ClosedBrowserTab] {
    closedTabs.reversed().filter { $0.spaceID == spaceID }
  }

  /// Fresh IDs keep delayed native-close callbacks from deleting a reopened tab.
  @discardableResult
  public mutating func reopenClosedTab(_ id: UUID, in spaceID: UUID) -> UUID? {
    guard selectedSpaceID == spaceID,
      let space = spaces.firstIndex(where: { $0.id == spaceID }),
      let entry = closedTabs.firstIndex(where: { $0.id == id && $0.spaceID == spaceID }),
      closedTabs[entry].profileID == spaces[space].profileID
    else { return nil }
    let snapshot = closedTabs[entry]
    let folder = snapshot.tab.folderID.flatMap { id in
      spaces[space].folders.contains { $0.id == id } ? id : nil
    }
    let tab = BrowserTab(
      url: snapshot.tab.url, title: snapshot.tab.title, isPinned: snapshot.tab.isPinned,
      folderID: folder)
    spaces[space].tabs.insert(tab, at: min(snapshot.index, spaces[space].tabs.count))
    spaces[space].selectedTabID = tab.id
    spaces[space].selectedFavoriteID = nil
    spaces[space].expandFolderPath(folder)
    closedTabs.remove(at: entry)
    return tab.id
  }

  @discardableResult
  public mutating func clearClosedTabs(in spaceID: UUID) -> Bool {
    guard selectedSpaceID == spaceID, closedTabs.contains(where: { $0.spaceID == spaceID })
    else { return false }
    closedTabs.removeAll { $0.spaceID == spaceID }
    return true
  }
}
