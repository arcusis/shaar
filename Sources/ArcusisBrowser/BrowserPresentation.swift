import BrowserCore

enum BrowserSheet: Identifiable {
  case space(SpaceEditorRoute)
  case extensionInstall(ExtensionInstallRequest)
  case websiteMedia(WebsiteMediaRequest)

  var id: String {
    switch self {
    case .space(let route): "space-\(route)"
    case .extensionInstall(let request): "install-\(request.id)"
    case .websiteMedia(let request): "media-\(request.id)"
    }
  }

  var isConsent: Bool {
    if case .space = self { return false }
    return true
  }

  func matches(_ session: BrowserSession) -> Bool {
    switch self {
    case .space: false
    case .extensionInstall(let request): request.matches(session)
    case .websiteMedia(let request): request.matches(session)
    }
  }
}
