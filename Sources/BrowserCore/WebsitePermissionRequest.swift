// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation

/// Website permissions the engine forwards for a decision, named as the engine reports them.
public enum WebsitePermissionKind: String, Sendable, CaseIterable {
  case camera, microphone, location, notifications, clipboard, midi
  case multipleDownloads, windowManagement, localFonts, storageAccess, protocolHandler

  /// Chromium can grant these for the current visit only; the rest are remembered when allowed.
  public var supportsOneTimeGrant: Bool {
    switch self {
    case .camera, .microphone, .location: true
    default: false
    }
  }
}

public enum WebsitePermissionPersistence: Equatable, Sendable {
  case thisVisit
  case profile

  /// Private profiles never keep a grant. Camera, microphone, and location stay on this visit.
  public static func forGrant(isPrivate: Bool, kinds: [WebsitePermissionKind]) -> Self {
    if isPrivate { return .thisVisit }
    if kinds.isEmpty { return .thisVisit }
    if kinds.allSatisfy(\.supportsOneTimeGrant) { return .thisVisit }
    return .profile
  }
}

public struct WebsitePermissionRequest: Identifiable, Equatable, Sendable {
  public let id: String
  public let profileID: UUID
  public let tabID: UUID
  public let pageURL: URL
  public let requestingOrigin: URL
  public let kinds: [WebsitePermissionKind]
  /// Chromium frame token for prompts that name a frame. Camera and microphone may omit it.
  public let frameID: String?

  /// Returns whether an HTTP or HTTPS origin is potentially trustworthy for browser prompts.
  public static func isSecureWebOrigin(_ origin: URL) -> Bool {
    let scheme = origin.scheme?.lowercased()
    return scheme == "https"
      || (scheme == "http" && isLocalHTTPHost(origin.host()?.lowercased() ?? ""))
  }

  public init?(
    id: String, profileID: UUID, tabID: UUID, pageURL: URL,
    requestingOrigin: URL, kinds: [WebsitePermissionKind], frameID: String? = nil
  ) {
    let storedFrame: String?
    if let frameID {
      guard let normalized = Self.normalizedFrameID(frameID) else { return nil }
      storedFrame = normalized
    } else {
      storedFrame = nil
    }
    guard !id.isEmpty, id.utf8.count <= 128, NavigationInput.isWebURL(pageURL),
      NavigationInput.isWebURL(requestingOrigin), requestingOrigin.user == nil,
      requestingOrigin.password == nil, requestingOrigin.query == nil,
      requestingOrigin.fragment == nil,
      requestingOrigin.path.isEmpty || requestingOrigin.path == "/",
      Self.isSecureWebOrigin(requestingOrigin), !kinds.isEmpty, Set(kinds).count == kinds.count
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.kinds = WebsitePermissionKind.allCases.filter(kinds.contains)
    self.frameID = storedFrame
  }

  /// Chromium's `base::Token::ToString` is 32 hexadecimal characters.
  public static func normalizedFrameID(_ value: String) -> String? {
    guard value.count == 32 else { return nil }
    let lowered = value.lowercased()
    let hex = CharacterSet(charactersIn: "0123456789abcdef")
    guard lowered.unicodeScalars.allSatisfy({ hex.contains($0) }) else { return nil }
    return lowered
  }

  private static func isLocalHTTPHost(_ host: String) -> Bool {
    ["localhost", "localhost.", "::1", "[::1]"].contains(host)
      || host.hasSuffix(".localhost") || host.hasSuffix(".localhost.")
      || isIPv4Loopback(host) || isIPv6Loopback(host)
  }

  private static func isIPv4Loopback(_ host: String) -> Bool {
    var address = in_addr()
    guard host.withCString({ inet_aton($0, &address) }) == 1 else { return false }
    return UInt32(bigEndian: address.s_addr) >> 24 == 127
  }

  private static func isIPv6Loopback(_ host: String) -> Bool {
    var address = in6_addr()
    guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
    var loopback = in6addr_loopback
    return memcmp(&address, &loopback, MemoryLayout<in6_addr>.size) == 0
  }

  public func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}

public enum WebsitePermissionIntake: Equatable, Sendable {
  case show(WebsitePermissionRequest)
  /// The id is already on screen. The new event is dropped and the live request stays.
  case ignoreDuplicate
  case deny
}

public enum WebsitePermissionEvent {
  /// A repeated id is ignored. Any other event that is not a current-page request is denied.
  public static func intake(
    from payload: [String: Any],
    windowID: String,
    outstandingIDs: Set<String>,
    knownTabs: Set<UUID>
  ) -> WebsitePermissionIntake {
    if let id = payload["id"] as? String, outstandingIDs.contains(id) {
      return .ignoreDuplicate
    }
    guard
      let request = request(
        from: payload, windowID: windowID, outstandingIDs: outstandingIDs, knownTabs: knownTabs)
    else { return .deny }
    return .show(request)
  }

  /// Accepts one permission event. Unknown kinds, a repeated id, the wrong tab, or
  /// schemaVersion other than 1 produce no request. Website permission prompts require a frame token.
  public static func request(
    from payload: [String: Any],
    windowID: String,
    outstandingIDs: Set<String>,
    knownTabs: Set<UUID>
  ) -> WebsitePermissionRequest? {
    guard schemaVersion(payload) == 1,
      let kind = payload["kind"] as? String,
      kind == "websitePermissionRequested" || kind == "websiteMediaRequested",
      let id = payload["id"] as? String,
      !outstandingIDs.contains(id),
      payload["windowID"] as? String == windowID,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      knownTabs.contains(tabID),
      let pageURL = (payload["pageURL"] as? String).flatMap(URL.init(string:)),
      let origin = (payload["origin"] as? String).flatMap(URL.init(string:)),
      let rawKinds = payload["permissions"] as? [String],
      !rawKinds.isEmpty,
      rawKinds.allSatisfy({ WebsitePermissionKind(rawValue: $0) != nil })
    else { return nil }
    let frameID = suppliedFrameID(payload)
    if payload["frameID"] != nil && frameID == nil { return nil }
    if kind == "websitePermissionRequested" && frameID == nil { return nil }
    return WebsitePermissionRequest(
      id: id, profileID: profileID, tabID: tabID, pageURL: pageURL,
      requestingOrigin: origin,
      kinds: rawKinds.compactMap(WebsitePermissionKind.init(rawValue:)),
      frameID: frameID)
  }

  private static func schemaVersion(_ payload: [String: Any]) -> Int? {
    guard let number = payload["schemaVersion"] as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    let integer = number.intValue
    guard number.doubleValue == Double(integer) else { return nil }
    return integer
  }

  private static func suppliedFrameID(_ payload: [String: Any]) -> String? {
    guard let raw = payload["frameID"] else { return nil }
    guard let text = raw as? String else { return nil }
    return WebsitePermissionRequest.normalizedFrameID(text)
  }
}
