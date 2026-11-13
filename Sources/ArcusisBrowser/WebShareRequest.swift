// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import CoreFoundation
import Foundation

enum WebShareOutcome: String, Equatable {
  case shared
  case cancelled
}

struct WebShareRequest: Identifiable, Equatable {
  let id: String
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  let requestingOrigin: URL
  let frameID: String
  let title: String
  let text: String
  let url: URL?

  init?(payload: [String: Any]) {
    guard let id = payload["id"] as? String,
      UUID(uuidString: id) != nil,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let pageURL = (payload["pageURL"] as? String).flatMap(URL.init(string:)),
      let requestingOrigin = (payload["origin"] as? String).flatMap(URL.init(string:)),
      let frameID = payload["frameID"] as? String,
      frameID.count >= 1, frameID.count <= 256,
      Self.isTrueBoolean(payload["userActivated"]),
      NavigationInput.isWebURL(pageURL),
      Self.secureOrigin(requestingOrigin),
      let title = Self.boundedText(payload["title"], maxUTF8: 2048, required: false),
      let text = Self.boundedText(payload["text"], maxUTF8: 4096, required: false),
      let link = Self.shareLink(payload["url"])
    else { return nil }
    let shareURL = Self.address(link)
    guard Self.filesAreEmpty(payload["files"]) else { return nil }
    guard !title.isEmpty || !text.isEmpty || shareURL != nil else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.frameID = frameID
    self.title = title
    self.text = text
    self.url = shareURL
  }

  var sheetID: String { "web-share-\(id)" }

  var originLabel: String {
    let origin = requestingOrigin.absoluteString
    return origin.hasSuffix("/") ? String(origin.dropLast()) : origin
  }

  var sharingItems: [Any] {
    var items: [Any] = []
    if let url { items.append(url as NSURL) }
    if !title.isEmpty { items.append(title as NSString) }
    if !text.isEmpty { items.append(text as NSString) }
    return items
  }

  func matches(
    _ session: BrowserSession, frameID: String? = nil, origin: URL? = nil
  ) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
      && (frameID == nil || self.frameID == frameID)
      && (origin == nil || requestingOrigin == origin)
  }

  private static func secureOrigin(_ origin: URL) -> Bool {
    guard NavigationInput.isWebURL(origin),
      origin.path.isEmpty || origin.path == "/",
      origin.query == nil,
      origin.fragment == nil,
      origin.user == nil,
      origin.password == nil
    else { return false }
    let scheme = origin.scheme?.lowercased()
    if scheme == "https" { return true }
    let host = origin.host()?.lowercased() ?? ""
    guard scheme == "http" else { return false }
    return host == "localhost" || host == "localhost."
      || host.hasSuffix(".localhost") || host.hasSuffix(".localhost.")
      || host == "::1" || host == "[::1]"
      || Self.isIPv4Loopback(host)
  }

  private static func isIPv4Loopback(_ host: String) -> Bool {
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4,
      octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      let first = UInt8(octets[0]), first == 127,
      octets.dropFirst().allSatisfy({ UInt8($0) != nil })
    else { return false }
    return true
  }

  private enum ShareLink {
    case absent
    case page(URL)
  }

  /// A missing or empty URL is allowed. A non-web URL rejects the request.
  private static func shareLink(_ value: Any?) -> ShareLink? {
    guard let value else { return .absent }
    guard let text = value as? String, text.utf8.count <= 4096 else { return nil }
    if text.isEmpty { return .absent }
    guard let url = URL(string: text), NavigationInput.isWebURL(url),
      url.user == nil, url.password == nil
    else { return nil }
    return .page(url)
  }

  private static func address(_ link: ShareLink) -> URL? {
    if case .page(let url) = link { return url }
    return nil
  }

  private static func boundedText(_ value: Any?, maxUTF8: Int, required: Bool) -> String? {
    guard let value else { return required ? nil : "" }
    guard let text = value as? String, text.utf8.count <= maxUTF8 else { return nil }
    return text
  }

  private static func isTrueBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
  }

  private static func filesAreEmpty(_ value: Any?) -> Bool {
    guard let value else { return true }
    guard let files = value as? [Any] else { return false }
    return files.isEmpty
  }
}
