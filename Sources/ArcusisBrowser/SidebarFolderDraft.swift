import BrowserCore
import Foundation

struct SidebarFolderDraft: Equatable {
  let route: FolderEditorRoute
  var name = "Untitled"

  var spaceID: UUID { route.spaceID }
  var parentID: UUID? {
    guard case .create(_, let parentID) = route else { return nil }
    return parentID
  }

  func isValid(in session: BrowserSession) -> Bool {
    guard case .create = route else { return false }
    return route.matches(session)
  }
}
