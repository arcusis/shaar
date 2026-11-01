// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Security

extension PageReloadMode {
  var engineMode: ARCPageReloadMode {
    switch self {
    case .normal: .normal
    case .bypassingCache: .bypassingCache
    case .newRenderer: .newRenderer
    }
  }
}

private struct SiteControlFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

extension BrowserEngine: SiteControlBackend {
  /// The selected live page of this window, if it can take site controls.
  var siteControlTarget: SiteControlTarget? {
    guard !isClosed, let store, let page = store.session.selectedPage,
      let profile = store.session.profileID(forTabID: page.tab.id),
      liveTabs.contains(page.tab.id),
      runtime.windowID(forTabID: page.tab.id.uuidString) == windowID
    else { return nil }
    return SiteControlTarget(tabID: page.tab.id, profileID: profile, url: page.tab.url)
  }

  func security(of target: SiteControlTarget) -> SiteSecurity {
    let info = runtime.securityInfo(
      forTabID: target.tabID.uuidString, profileID: target.profileID.uuidString)
    return SiteSecurity(engineLevel: info?["level"] as? String)
  }

  func permissionValues(for target: SiteControlTarget) async throws -> [SitePermission:
    SitePermissionValue]
  {
    let origin = try webOrigin(of: target)
    let settings = try await runtime.siteSettings(
      forOrigin: origin, profileID: target.profileID.uuidString)
    var values = SitePermissionValues.parse(settings)
    values[.autoPictureInPicture] = autoPictureInPictureValue(for: target)
    return values
  }

  func setPermission(_ permission: SitePermission, allowed: Bool, for target: SiteControlTarget)
    async throws
  {
    let origin = try webOrigin(of: target)
    guard let name = permission.engineSettingName else {
      store?.setAutomaticPictureInPicture(allowed, for: target.url, profileID: target.profileID)
      return
    }
    try await runtime.setSiteSetting(
      name, value: allowed ? "allow" : "block", origin: origin,
      profileID: target.profileID.uuidString)
  }

  func perform(_ action: SiteAction, for target: SiteControlTarget) async throws {
    let profile = target.profileID.uuidString
    switch action {
    case .reload: try reload(target, .normal)
    case .hardReload: try reload(target, .bypassingCache)
    case .clearCacheAndReload:
      try await runtime.clearCache(forProfileID: profile)
      try reload(target, .bypassingCache)
    case .clearCookiesAndReload:
      try await runtime.clearCookies(forTabID: target.tabID.uuidString, profileID: profile)
      try reload(target, .normal)
    case .clearSiteData:
      try await runtime.clearSiteData(forOrigin: try webOrigin(of: target), profileID: profile)
    case .restartPage: try reload(target, .newRenderer)
    }
  }

  /// The chain the site presents, accepted only when its leaf is the certificate Chromium
  /// loaded the page with.
  func certificateChain(for target: SiteControlTarget) async throws -> [SecCertificate] {
    let info = runtime.securityInfo(
      forTabID: target.tabID.uuidString, profileID: target.profileID.uuidString)
    let summary = info?["certificate"] as? [String: Any]
    guard let fingerprint = summary?["sha256"] as? String,
      let host = target.url.host(percentEncoded: false)
    else { throw SiteControlFailure("This page has no certificate to show.") }
    let chain = try await SiteCertificateChain.fetch(
      host: host, port: UInt16(target.url.port ?? 443))
    guard let leaf = chain.first, SiteCertificateChain.fingerprint(fingerprint, matches: leaf)
    else {
      throw SiteControlFailure("The site presented a different certificate than this page uses.")
    }
    return chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
  }

  /// Reloads through the store so renderer-failure state and stale-target checks stay shared.
  private func reload(_ target: SiteControlTarget, _ mode: PageReloadMode) throws {
    guard siteControlTarget == target, store?.reloadCurrentPage(mode) == true else {
      throw SiteControlFailure("This page can no longer be reloaded from here.")
    }
  }

  private func webOrigin(of target: SiteControlTarget) throws -> String {
    guard let origin = target.origin else {
      throw SiteControlFailure("Site controls are available for web pages only.")
    }
    return origin
  }

  private func autoPictureInPictureValue(for target: SiteControlTarget) -> SitePermissionValue {
    let allowed =
      store?.automaticPictureInPictureAllowed(for: target.url, profileID: target.profileID) ?? true
    return allowed ? .allow : .block
  }
}
