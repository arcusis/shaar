import BrowserCore
import Foundation

enum BookmarkEditorMode: Equatable {
  case newBookmark(parent: UUID?, title: String, address: String)
  case newFolder(parent: UUID?)
  case edit(UUID)
}

struct BookmarkEditorRoute: Identifiable, Equatable {
  let id = UUID()
  let profileID: UUID
  let mode: BookmarkEditorMode

  var itemID: UUID? { if case .edit(let id) = mode { id } else { nil } }
  var parentID: UUID? {
    switch mode {
    case .newBookmark(let parent, _, _), .newFolder(let parent): parent
    case .edit: nil
    }
  }

  @MainActor func matches(_ store: BrowserStore) -> Bool {
    guard store.session.selectedSpace.profileID == profileID else { return false }
    let tree = store.library.bookmarks[profileID]
    switch mode {
    case .edit(let id): return tree?.items.contains { $0.id == id && !$0.isPermanent } == true
    case .newBookmark, .newFolder:
      return parentID == nil || tree?.items.contains { $0.id == parentID && $0.isFolder } == true
    }
  }
}
