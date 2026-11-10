// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum PagePromptKind: String, Equatable {
  case display
  case share
  case print
}

struct PagePromptSignal: Equatable {
  static let marker = "\u{2060}shaar-prompt\u{2060}"
  let kind: PagePromptKind
  let id: String

  static func parse(_ title: String) -> PagePromptSignal? {
    guard let range = title.range(of: marker) else { return nil }
    let parts = title[range.upperBound...].split(
      separator: "\u{2060}", omittingEmptySubsequences: false)
    guard parts.count == 2, let kind = PagePromptKind(rawValue: String(parts[0])),
      UUID(uuidString: String(parts[1])) != nil
    else { return nil }
    return PagePromptSignal(kind: kind, id: String(parts[1]))
  }

  static func visibleTitle(reported: String, previous: String) -> String {
    parse(reported) == nil ? reported : previous
  }
}

enum PagePromptCapture {
  static func request(
    signal: PagePromptSignal, tabID: UUID, profileID: UUID, pageURL: URL
  ) -> DesktopCaptureRequest? {
    guard signal.kind == .display, let origin = origin(of: pageURL) else { return nil }
    return DesktopCaptureRequest(payload: [
      "id": signal.id,
      "profileID": profileID.uuidString,
      "tabID": tabID.uuidString,
      "pageURL": pageURL.absoluteString,
      "origin": origin.absoluteString,
      "frameID": "main",
    ])
  }

  static func origin(of pageURL: URL) -> URL? {
    guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), components.host != nil
    else { return nil }
    components.scheme = scheme
    components.user = nil
    components.password = nil
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
  }
}
