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

enum DesktopCaptureCatalog {
  static let screenAccessNote =
    "Screen Recording access is unavailable. Check Privacy & Security settings."
  static let emptySources = "No screens, windows, or tabs are available"

  static func allowedSources(
    _ sources: [DesktopCaptureSource], for request: DesktopCaptureRequest
  ) -> [DesktopCaptureSource] {
    sources.filter { request.allows($0.kind) }
  }

  static func tabSources(
    session: BrowserSession, profileID: UUID, requestingTabID: UUID
  ) -> [DesktopCaptureSource] {
    var requesting: [DesktopCaptureSource] = []
    var others: [DesktopCaptureSource] = []
    var seen: Set<UUID> = []
    for space in session.spaces where space.profileID == profileID {
      for tab in space.tabs where seen.insert(tab.id).inserted {
        let source = DesktopCaptureSource(
          id: "tab:\(tab.id.uuidString):0", name: tab.title, kind: .tab,
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
    tabs: [DesktopCaptureSource], screens: [DesktopCaptureSource], screenAccessFailed: Bool
  ) -> DesktopCaptureListing {
    let sources = tabs + screens
    if sources.isEmpty {
      let message = screenAccessFailed ? screenAccessNote : emptySources
      return DesktopCaptureListing(sources: [], note: nil, error: message)
    }
    return DesktopCaptureListing(
      sources: sources, note: screenAccessFailed ? screenAccessNote : nil, error: nil)
  }
}
