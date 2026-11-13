// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct DesktopCaptureListing: Equatable {
  var sources: [DesktopCaptureSource]
  var note: String?
  var error: String?
}

struct DesktopCaptureSettingsAction: Equatable {
  let title: String
  let destination: URL
}

enum DesktopCaptureCatalog {
  static let screenAccessNote =
    "Screen Recording access is unavailable. Check Privacy & Security settings."
  static let screenEnumerationNote = "Screen sources could not be loaded. Try again."
  static let emptySources = "No sharing sources match this request."

  static func settingsAction(for message: String?) -> DesktopCaptureSettingsAction? {
    guard message == screenAccessNote, let destination = MacPermission.screenRecording.settingsURL
    else { return nil }
    return DesktopCaptureSettingsAction(
      title: PanelsL10n.string("Open Settings"), destination: destination)
  }

  static func allowedSources(
    _ sources: [DesktopCaptureSource], for request: DesktopCaptureRequest
  ) -> [DesktopCaptureSource] {
    var seen: Set<String> = []
    return sources.filter {
      guard DesktopCaptureSource.kind(forToken: $0.id) == $0.kind, request.allows($0.kind) else {
        return false
      }
      return seen.insert($0.id).inserted
    }
  }

  static func windowName(owner: String?, title: String?) -> String {
    let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return switch (owner.isEmpty, title.isEmpty) {
    case (false, false): "\(owner) — \(title)"
    case (false, true): owner
    case (true, false): title
    case (true, true): PanelsL10n.string("Window")
    }
  }

  static func tabSources(
    session: BrowserSession, profileID: UUID, requestingTabID: UUID
  ) -> [DesktopCaptureSource] {
    var requesting: [DesktopCaptureSource] = []
    var others: [DesktopCaptureSource] = []
    var seen: Set<UUID> = []
    for space in session.spaces where space.profileID == profileID {
      for tab in space.tabs
      where NavigationInput.isWebURL(tab.url) && seen.insert(tab.id).inserted {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? tab.url.host() ?? tab.url.absoluteString : title
        let source = DesktopCaptureSource(
          id: "tab:\(tab.id.uuidString):0", name: name, kind: .tab,
          isRequestingTab: tab.id == requestingTabID)
        if tab.id == requestingTabID {
          requesting.append(source)
        } else {
          others.append(source)
        }
      }
    }
    return requesting + others
  }

  static func listing(
    tabs: [DesktopCaptureSource], screens: [DesktopCaptureSource], screenAccessFailed: Bool,
    screenEnumerationFailed: Bool = false
  ) -> DesktopCaptureListing {
    let sources = tabs + screens
    if sources.isEmpty {
      let message: String
      if screenEnumerationFailed {
        message = screenEnumerationNote
      } else {
        message = screenAccessFailed ? screenAccessNote : emptySources
      }
      return DesktopCaptureListing(sources: [], note: nil, error: message)
    }
    return DesktopCaptureListing(
      sources: sources,
      note: screenAccessFailed ? screenAccessNote : (screenEnumerationFailed ? screenEnumerationNote : nil),
      error: nil)
  }
}
