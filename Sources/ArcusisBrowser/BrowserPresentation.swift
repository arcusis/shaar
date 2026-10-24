import BrowserCore
import Foundation

enum BrowserSheet: Identifiable {
  case space(SpaceEditorRoute)
  case extensionInstall(ExtensionInstallRequest)
  case websiteMedia(WebsiteMediaRequest)
  case downloads(profileID: UUID)

  var id: String {
    switch self {
    case .space(let route): "space-\(route)"
    case .extensionInstall(let request): "install-\(request.id)"
    case .websiteMedia(let request): "media-\(request.id)"
    case .downloads(let profile): "downloads-\(profile)"
    }
  }

  var isConsent: Bool {
    switch self {
    case .space, .downloads: false
    case .extensionInstall, .websiteMedia: true
    }
  }

  func matches(_ session: BrowserSession) -> Bool {
    switch self {
    case .space, .downloads: false
    case .extensionInstall(let request): request.matches(session)
    case .websiteMedia(let request): request.matches(session)
    }
  }
}
