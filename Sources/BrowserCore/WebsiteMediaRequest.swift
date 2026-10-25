import Foundation

public enum WebsiteMediaKind: String, Sendable, CaseIterable {
  case camera, microphone
}

public struct WebsiteMediaRequest: Identifiable, Equatable, Sendable {
  public let id: String
  public let profileID: UUID
  public let tabID: UUID
  public let pageURL: URL
  public let requestingOrigin: URL
  public let kinds: [WebsiteMediaKind]

  public init?(
    id: String, profileID: UUID, tabID: UUID, pageURL: URL,
    requestingOrigin: URL, kinds: [WebsiteMediaKind]
  ) {
    let scheme = requestingOrigin.scheme?.lowercased()
    let secureOrigin =
      scheme == "https"
      || (scheme == "http"
        && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(
          requestingOrigin.host()?.lowercased() ?? ""))
    guard !id.isEmpty, id.utf8.count <= 128, NavigationInput.isWebURL(pageURL),
      NavigationInput.isWebURL(requestingOrigin), requestingOrigin.user == nil,
      requestingOrigin.password == nil, requestingOrigin.query == nil,
      requestingOrigin.fragment == nil,
      requestingOrigin.path.isEmpty || requestingOrigin.path == "/",
      secureOrigin, !kinds.isEmpty, kinds.count <= 2, Set(kinds).count == kinds.count
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.kinds = WebsiteMediaKind.allCases.filter(kinds.contains)
  }

  public func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}
