import BrowserCore
import Foundation

extension BrowserStore {
  func showLibrary(_ section: LibrarySection) {
    guard sheet == nil else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    let profile = session.selectedSpace.profileID
    sheet = .library(profileID: profile, section: section)
    library.refresh(profile, section: section)
  }

  var canBookmarkCurrentPage: Bool {
    sheet == nil
      && session.selectedPage.map { NavigationInput.isWebURL($0.tab.url) } == true
  }

  func bookmarkCurrentPage() {
    guard canBookmarkCurrentPage, let page = session.selectedPage?.tab else { return }
    let profile = session.selectedSpace.profileID
    if let existing = library.bookmarks[profile]?.items.first(where: { $0.destination == page.url })
    {
      showBookmarkEditor(BookmarkEditorRoute(profileID: profile, mode: .edit(existing.id)))
    } else {
      showBookmarkEditor(
        BookmarkEditorRoute(
          profileID: profile,
          mode: .newBookmark(parent: nil, title: page.title, address: page.url.absoluteString)))
    }
  }

  func showBookmarkEditor(_ route: BookmarkEditorRoute) {
    guard mayUseLibrary(route.profileID), route.matches(self) else { return }
    dismissCommand()
    dismissPageFind()
    engine?.extensionPanel = nil
    sheet = .bookmarkEditor(route)
    if library.bookmarks[route.profileID] == nil {
      library.refresh(route.profileID, section: .bookmarks)
    }
  }

  private func mayUseLibrary(_ profile: UUID, editing: Bool = false) -> Bool {
    guard session.selectedSpace.profileID == profile else { return false }
    switch sheet {
    case nil: return true
    case .library(let owner, _): return owner == profile
    case .bookmarkEditor(let route):
      return editing && route.profileID == profile && route.matches(self)
    default: return false
    }
  }

  @discardableResult
  func saveBookmark(_ route: BookmarkEditorRoute, title: String, address: String, parentID: UUID?)
    -> Bool
  {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard mayUseLibrary(route.profileID, editing: true),
      sheet?.id == BrowserSheet.bookmarkEditor(route).id,
      !title.isEmpty, title.utf8.count <= 4096, let tree = library.bookmarks[route.profileID]
    else { return false }
    var operation: [String: Any]
    switch route.mode {
    case .edit(let id):
      guard let item = tree.items.first(where: { $0.id == id }), !item.isPermanent else {
        return false
      }
      operation = ["op": "update", "id": id.uuidString.lowercased(), "t": title]
      if !item.isFolder {
        guard
          let url = LibraryAddress.destination(
            address.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        operation["u"] = url.absoluteString
      }
    case .newBookmark, .newFolder:
      let parent = parentID ?? tree.otherID
      guard tree.items.contains(where: { $0.id == parent && $0.isFolder }) else { return false }
      operation = [
        "op": "add", "id": route.id.uuidString.lowercased(),
        "parent": parent.uuidString.lowercased(), "t": title,
      ]
      if case .newFolder = route.mode {
        operation["k"] = "f"
      } else {
        guard
          let url = LibraryAddress.destination(
            address.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        operation["k"] = "u"
        operation["u"] = url.absoluteString
      }
    }
    return library.mutate(.bookmark(operation), profile: route.profileID) { [weak self] success in
      guard let self, success, self.sheet?.id == BrowserSheet.bookmarkEditor(route).id else {
        return
      }
      self.sheet = nil
    }
  }

  @discardableResult
  func deleteBookmark(_ id: UUID, profileID: UUID) -> Bool {
    guard mayUseLibrary(profileID, editing: true),
      library.bookmarks[profileID]?.items.contains(where: { $0.id == id && !$0.isPermanent })
        == true
    else { return false }
    return library.mutate(
      .bookmark(["op": "remove", "id": id.uuidString.lowercased()]), profile: profileID
    ) { [weak self] success in
      guard let self, success, case .bookmarkEditor(let route) = self.sheet,
        route.itemID == id && route.profileID == profileID
      else { return }
      self.sheet = nil
    }
  }

  @discardableResult
  func moveBookmark(_ id: UUID, profileID: UUID, to parent: UUID) -> Bool {
    guard mayUseLibrary(profileID), let tree = library.bookmarks[profileID],
      tree.items.contains(where: { $0.id == id && !$0.isPermanent }),
      tree.items.contains(where: { $0.id == parent && $0.isFolder }),
      !tree.contains(id, inPathTo: parent)
    else { return false }
    return library.mutate(
      .bookmark([
        "op": "move", "id": id.uuidString.lowercased(), "parent": parent.uuidString.lowercased(),
      ]), profile: profileID
    ) { _ in }
  }

  @discardableResult
  func deleteHistoryEntry(_ address: String, profileID: UUID) -> Bool {
    guard mayUseLibrary(profileID),
      library.history[profileID]?.contains(where: { $0.address == address }) == true
    else { return false }
    return library.mutate(.deleteHistory(address), profile: profileID) { _ in }
  }

  @discardableResult
  func openBookmark(_ id: UUID, profileID: UUID) -> Bool {
    guard mayUseLibrary(profileID),
      let item = library.bookmarks[profileID]?.items.first(where: { $0.id == id }),
      let url = item.destination
    else { return false }
    if case .library = sheet { sheet = nil }
    perform(.open(url))
    return true
  }

  @discardableResult
  func openHistoryEntry(_ address: String, profileID: UUID) -> Bool {
    guard mayUseLibrary(profileID),
      let entry = library.history[profileID]?.first(where: { $0.address == address }),
      let url = entry.destination
    else { return false }
    if case .library = sheet { sheet = nil }
    perform(.open(url))
    return true
  }
}
