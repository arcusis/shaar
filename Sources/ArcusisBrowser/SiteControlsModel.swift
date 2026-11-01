// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation
import Security

/// How the selected page reloads.
enum PageReloadMode: Equatable, Sendable {
  case normal
  /// Revalidates every resource with its server instead of using cached copies.
  case bypassingCache
  /// Loads the page again in a new renderer process.
  case newRenderer
}

/// The selected page the site control center acts on.
struct SiteControlTarget: Equatable {
  let tabID: UUID
  let profileID: UUID
  let url: URL

  var origin: String? { SiteOrigin.string(for: url) }
  var host: String { url.host(percentEncoded: false) ?? url.absoluteString }
}

/// Page actions offered by the site control center, in display order.
enum SiteAction: String, CaseIterable, Identifiable {
  case reload, hardReload, clearCacheAndReload, clearCookiesAndReload, clearSiteData, restartPage

  var id: String { rawValue }

  var title: String {
    switch self {
    case .reload: "Reload"
    case .hardReload: "Hard Reload"
    case .clearCacheAndReload: "Clear Cache and Reload"
    case .clearCookiesAndReload: "Clear Cookies and Reload"
    case .clearSiteData: "Clear All Site Data"
    case .restartPage: "Restart Page"
    }
  }

  var symbol: String {
    switch self {
    case .reload: "arrow.clockwise"
    case .hardReload: "arrow.clockwise.circle"
    case .clearCacheAndReload: "internaldrive"
    case .clearCookiesAndReload: "birthday.cake"
    case .clearSiteData: "trash"
    case .restartPage: "power"
    }
  }

  var help: String {
    switch self {
    case .reload: "Reload this page (Command-R)"
    case .hardReload: "Reload without cached files (Command-Shift-R)"
    case .clearCacheAndReload: "Empty this profile's cache, then reload without cached files"
    case .clearCookiesAndReload: "Delete the cookies this page uses, then reload"
    case .clearSiteData: "Delete cookies and stored data for this site in this profile"
    case .restartPage: "Reload this page in a new renderer process"
    }
  }

  /// Clearing data needs a web page; reloads work for any page.
  var needsWebOrigin: Bool {
    switch self {
    case .clearCookiesAndReload, .clearSiteData: true
    default: false
    }
  }
}

/// Engine operations behind the site control center, scoped to one target page.
@MainActor
protocol SiteControlBackend: AnyObject {
  func security(of target: SiteControlTarget) -> SiteSecurity
  func permissionValues(for target: SiteControlTarget) async throws -> [SitePermission:
    SitePermissionValue]
  func setPermission(_ permission: SitePermission, allowed: Bool, for target: SiteControlTarget)
    async throws
  func perform(_ action: SiteAction, for target: SiteControlTarget) async throws
  func certificateChain(for target: SiteControlTarget) async throws -> [SecCertificate]
}

@MainActor @Observable
final class SiteControlsModel: Identifiable {
  let id = UUID()
  let target: SiteControlTarget
  private(set) var security: SiteSecurity
  private(set) var permissionValues: [SitePermission: SitePermissionValue] = [:]
  private(set) var runningAction: SiteAction?
  private(set) var failure: String?
  @ObservationIgnored private weak var backend: SiteControlBackend?

  init(target: SiteControlTarget, backend: SiteControlBackend) {
    self.target = target
    self.backend = backend
    security = backend.security(of: target)
  }

  /// Permissions this page can change; all are unavailable outside web pages.
  var permissions: [SitePermission] {
    target.origin == nil ? [] : SitePermission.allCases
  }

  func isAllowed(_ permission: SitePermission) -> Bool {
    permissionValues[permission] == .allow
  }

  func isAvailable(_ action: SiteAction) -> Bool {
    runningAction == nil && (!action.needsWebOrigin || target.origin != nil)
  }

  func load() async {
    guard let backend, target.origin != nil else { return }
    do {
      permissionValues = try await backend.permissionValues(for: target)
    } catch {
      failure = error.localizedDescription
    }
  }

  func setPermission(_ permission: SitePermission, allowed: Bool) async {
    guard let backend else { return }
    let previous = permissionValues[permission]
    permissionValues[permission] = allowed ? .allow : .block
    do {
      try await backend.setPermission(permission, allowed: allowed, for: target)
      failure = nil
    } catch {
      permissionValues[permission] = previous
      failure = error.localizedDescription
    }
  }

  /// Runs one action; returns whether it finished so the caller can close the panel.
  func perform(_ action: SiteAction) async -> Bool {
    guard let backend, isAvailable(action) else { return false }
    runningAction = action
    defer { runningAction = nil }
    do {
      try await backend.perform(action, for: target)
      failure = nil
      return true
    } catch {
      failure = error.localizedDescription
      return false
    }
  }

  /// Only pages loaded over HTTPS have a certificate chain to show.
  var hasCertificate: Bool { target.url.scheme?.lowercased() == "https" }

  func certificateChain() async -> [SecCertificate]? {
    guard let backend, hasCertificate else { return nil }
    do {
      return try await backend.certificateChain(for: target)
    } catch {
      failure = error.localizedDescription
      return nil
    }
  }
}
