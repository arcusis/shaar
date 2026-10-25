import BrowserCore
import Foundation

enum BrowserSheet: Identifiable {
  case space(SpaceEditorRoute)
  case extensionInstall(ExtensionInstallRequest)
  case websiteMedia(WebsiteMediaRequest)
  case externalApp(ExternalAppRequest)
  case downloads(profileID: UUID)
  case folder(FolderEditorRoute)
  case recentlyClosed(spaceID: UUID)
  case library(profileID: UUID, section: LibrarySection)
  case bookmarkEditor(BookmarkEditorRoute)

  var id: String {
    switch self {
    case .space(let route): "space-\(route)"
    case .extensionInstall(let request): "install-\(request.id)"
    case .websiteMedia(let request): "media-\(request.id)"
    case .externalApp(let request): "external-\(request.id)"
    case .downloads(let profile): "downloads-\(profile)"
    case .folder(let route): "folder-\(route)"
    case .recentlyClosed(let space): "closed-\(space)"
    case .library(let profile, let section): "library-\(profile)-\(section)"
    case .bookmarkEditor(let route): "bookmark-\(route.id)"
    }
  }

  var isConsent: Bool {
    switch self {
    case .space, .downloads, .folder, .recentlyClosed, .library, .bookmarkEditor: false
    case .extensionInstall, .websiteMedia, .externalApp: true
    }
  }

  var tabID: UUID? {
    switch self {
    case .extensionInstall(let request): request.tabID
    case .websiteMedia(let request): request.tabID
    case .externalApp(let request): request.tabID
    default: nil
    }
  }

  func matches(_ session: BrowserSession) -> Bool {
    switch self {
    case .space, .downloads, .folder, .recentlyClosed, .library, .bookmarkEditor: false
    case .extensionInstall(let request): request.matches(session)
    case .websiteMedia(let request): request.matches(session)
    case .externalApp(let request): request.matches(session)
    }
  }
}
