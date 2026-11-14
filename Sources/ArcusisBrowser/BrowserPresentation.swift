// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

enum SidebarVisibility: Equatable {
  case pinned
  case hidden
  case revealed

  mutating func setPinned(_ pinned: Bool) {
    self = pinned ? .pinned : .hidden
  }

  mutating func pointerEnteredEdge() {
    if self == .hidden { self = .revealed }
  }

  mutating func pointerLeftSidebar() {
    if self == .revealed { self = .hidden }
  }
}

enum BrowserSheet: Identifiable {
  case space(SpaceEditorRoute)
  case extensionInstall(ExtensionInstallRequest)
  case websitePermission(WebsitePermissionRequest)
  case desktopCapture(DesktopCaptureRequest)
  case webShare(WebShareRequest)
  case print(PrintRequest)
  case javascriptDialog(JavaScriptDialogRequest)
  case externalApp(ExternalAppRequest)
  case deviceChooser(DeviceChooserRequest)
  case httpAuth(HTTPAuthRequest)
  case downloads(profileID: UUID)
  case folder(FolderEditorRoute)
  case recentlyClosed(spaceID: UUID)
  case library(profileID: UUID, section: LibrarySection)
  case bookmarkEditor(BookmarkEditorRoute)

  var id: String {
    switch self {
    case .space(let route): "space-\(route)"
    case .extensionInstall(let request): "install-\(request.id)"
    case .websitePermission(let request): "permission-\(request.id)"
    case .desktopCapture(let request): request.sheetID
    case .webShare(let request): request.sheetID
    case .print(let request): request.sheetID
    case .javascriptDialog(let request): request.sheetID
    case .externalApp(let request): "external-\(request.id)"
    case .deviceChooser(let request): request.sheetID
    case .httpAuth(let request): request.sheetID
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
    case .extensionInstall, .websitePermission, .desktopCapture, .webShare, .print, .externalApp,
      .deviceChooser, .httpAuth, .javascriptDialog:
      true
    }
  }

  var tabID: UUID? {
    switch self {
    case .extensionInstall(let request): request.tabID
    case .websitePermission(let request): request.tabID
    case .desktopCapture(let request): request.tabID
    case .webShare(let request): request.tabID
    case .print(let request): request.tabID
    case .javascriptDialog(let request): request.tabID
    case .externalApp(let request): request.tabID
    case .deviceChooser(let request): request.tabID
    case .httpAuth(let request): request.tabID
    default: nil
    }
  }

  func matches(_ session: BrowserSession) -> Bool {
    switch self {
    case .space, .downloads, .folder, .recentlyClosed, .library, .bookmarkEditor: false
    case .extensionInstall(let request): request.matches(session)
    case .websitePermission(let request): request.matches(session)
    case .desktopCapture(let request): request.matches(session)
    case .webShare(let request): request.matches(session)
    case .print(let request): request.matches(session)
    case .javascriptDialog(let request): request.matches(session)
    case .externalApp(let request): request.matches(session)
    case .deviceChooser(let request): request.matches(session)
    case .httpAuth(let request): request.matches(session)
    }
  }
}
