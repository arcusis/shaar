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
  func sharesPanelTab(with other: Self) -> Bool {
    tabID == other.tabID && profileID == other.profileID
  }
  var host: String {
    guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
    guard let port = url.port else { return host }
    if host.contains(":") { return "[\(host)]:\(port)" }
    return "\(host):\(port)"
  }
}

/// Page actions offered by the site control center, in display order.
enum SiteAction: String, CaseIterable, Identifiable {
  case reload, hardReload, clearCacheAndReload, clearCookiesAndReload, clearSiteData, restartPage

  var id: String { rawValue }

  var title: String {
    title(language: .currentLaunchLanguage)
  }

  func title(language: BrowserLanguage) -> String {
    switch self {
    case .reload: BrowserLocalization.string("Reload", table: "Shell", language: language)
    case .hardReload:
      BrowserLocalization.string("Hard Reload", table: "Shell", language: language)
    case .clearCacheAndReload:
      BrowserLocalization.string("Clear Cache and Reload", table: "Shell", language: language)
    case .clearCookiesAndReload:
      BrowserLocalization.string("Clear Cookies and Reload", table: "Shell", language: language)
    case .clearSiteData:
      BrowserLocalization.string("Clear All Site Data", table: "Shell", language: language)
    case .restartPage:
      BrowserLocalization.string("Restart Page", table: "Shell", language: language)
    }
  }

  func failureNotice(language: BrowserLanguage = .currentLaunchLanguage) -> String {
    BrowserLocalization.format(
      "Could not complete the %@ action. Try again.", table: "Shell", language: language,
      arguments: [.string(title(language: language))])
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
    case .reload: ShellL10n.string("Reload this page (Command-R)")
    case .hardReload: ShellL10n.string("Reload without cached files (Command-Shift-R)")
    case .clearCacheAndReload:
      ShellL10n.string("Empty this profile's cache, then reload without cached files")
    case .clearCookiesAndReload: ShellL10n.string("Delete the cookies this page uses, then reload")
    case .clearSiteData:
      ShellL10n.string("Delete cookies and stored data for this site in this profile")
    case .restartPage: ShellL10n.string("Reload this page in a new renderer process")
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
  private(set) var savingPermissions: Set<SitePermission> = []
  private(set) var runningAction: SiteAction?
  private(set) var failure: String?
  @ObservationIgnored private weak var backend: SiteControlBackend?
  @ObservationIgnored private var permissionChangeRevision = 0
  @ObservationIgnored private var permissionLoadRevision = 0

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
    permissionLoadRevision += 1
    let loadRevision = permissionLoadRevision
    let changeRevision = permissionChangeRevision
    do {
      let values = try await backend.permissionValues(for: target)
      guard !Task.isCancelled, loadRevision == permissionLoadRevision,
        changeRevision == permissionChangeRevision
      else {
        return
      }
      var refreshed = values
      for permission in savingPermissions {
        refreshed[permission] = permissionValues[permission]
      }
      permissionValues = refreshed
      failure = nil
    } catch {
      guard !Task.isCancelled, loadRevision == permissionLoadRevision,
        changeRevision == permissionChangeRevision
      else {
        return
      }
      failure = ShellL10n.string("Could not load site permissions. Try again.")
    }
  }

  func setPermission(_ permission: SitePermission, allowed: Bool) async {
    guard let backend, !savingPermissions.contains(permission) else { return }
    permissionChangeRevision += 1
    savingPermissions.insert(permission)
    defer {
      savingPermissions.remove(permission)
      permissionChangeRevision += 1
    }
    let previous = permissionValues[permission]
    permissionValues[permission] = allowed ? .allow : .block
    do {
      try await backend.setPermission(permission, allowed: allowed, for: target)
      guard !Task.isCancelled else { return }
      failure = nil
    } catch is CancellationError {
      permissionValues[permission] = previous
    } catch {
      guard !Task.isCancelled else { return }
      permissionValues[permission] = previous
      guard !Task.isCancelled else { return }
      failure = ShellL10n.string("Could not update this permission. Try again.")
    }
  }

  /// Runs one action; returns whether it finished so the caller can close the panel.
  func perform(_ action: SiteAction) async -> Bool {
    guard let backend, isAvailable(action) else { return false }
    runningAction = action
    defer { runningAction = nil }
    do {
      try await backend.perform(action, for: target)
      guard !Task.isCancelled else { return false }
      failure = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard !Task.isCancelled else { return false }
      failure = ShellL10n.format(
        "Could not complete the %@ action. Try again.", arguments: [.string(action.title)])
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
      failure = ShellL10n.string("Could not load this site’s certificate. Try again.")
      return nil
    }
  }
}
