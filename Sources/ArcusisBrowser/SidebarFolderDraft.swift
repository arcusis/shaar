import BrowserCore
import Foundation

struct SidebarFolderDraft: Equatable {
  let route: FolderEditorRoute
  let section: SidebarSection
  var name = "Untitled"

  init(route: FolderEditorRoute, section: SidebarSection = .pinned) {
    self.route = route
    self.section = section
  }

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
