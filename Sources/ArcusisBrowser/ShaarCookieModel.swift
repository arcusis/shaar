// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Observation
import ShaarEngineABI

@MainActor protocol ShaarCookieStore: AnyObject {
  func siteCookies(for target: SiteControlTarget) async throws -> [ShaarSiteCookie]
  func setSiteCookie(
    _ cookie: ShaarSiteCookie, value: String, secure: Bool, httpOnly: Bool,
    sameSite: ShaarCookieSameSite, for target: SiteControlTarget
  ) async throws
  func deleteSiteCookie(_ cookie: ShaarSiteCookie, for target: SiteControlTarget) async throws
}

private struct SiteCookieFailure: LocalizedError {
  let errorDescription: String?
  init(_ value: String) { errorDescription = ShellL10n.string(value) }
}

extension BrowserEngine: ShaarCookieStore {
  func siteCookies(for target: SiteControlTarget) async throws -> [ShaarSiteCookie] {
    let origin = try cookieOrigin(for: target)
    let rows = try await runtime.siteCookies(
      forTabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      origin: origin)
    guard siteControlTarget == target,
      rows.allSatisfy({ ShaarSiteCookie(dictionary: $0) != nil })
    else { throw SiteCookieFailure("The selected page has changed.") }
    return rows.compactMap(ShaarSiteCookie.init(dictionary:))
  }

  func setSiteCookie(
    _ cookie: ShaarSiteCookie, value: String, secure: Bool, httpOnly: Bool,
    sameSite: ShaarCookieSameSite, for target: SiteControlTarget
  ) async throws {
    let origin = try cookieOrigin(for: target)
    var payload = cookie.identity
    payload["value"] = value
    payload["secure"] = secure
    payload["httpOnly"] = httpOnly
    payload["sameSite"] = sameSite.rawValue
    try await runtime.setSiteCookie(
      payload, tabID: target.tabID.uuidString, profileID: target.profileID.uuidString,
      origin: origin)
  }

  func deleteSiteCookie(_ cookie: ShaarSiteCookie, for target: SiteControlTarget) async throws {
    let origin = try cookieOrigin(for: target)
    try await runtime.deleteSiteCookie(
      cookie.identity, tabID: target.tabID.uuidString,
      profileID: target.profileID.uuidString, origin: origin)
  }

  private func cookieOrigin(for target: SiteControlTarget) throws -> String {
    guard siteControlTarget == target, let origin = target.origin else {
      throw SiteCookieFailure("The selected page has changed.")
    }
    return origin
  }
}

@MainActor @Observable
final class ShaarCookieModel {
  private(set) var cookies: [ShaarSiteCookie] = []
  private(set) var loading = false
  private(set) var saving = false
  var search = ""
  var selectedID: String?
  var failure: String?
  @ObservationIgnored private weak var store: (any ShaarCookieStore)?
  @ObservationIgnored private var target: SiteControlTarget?
  @ObservationIgnored private var revision = 0

  var selected: ShaarSiteCookie? { cookies.first { $0.id == selectedID } }
  var visibleCookies: [ShaarSiteCookie] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return cookies }
    return cookies.filter {
      $0.name.localizedStandardContains(needle) || $0.domain.localizedStandardContains(needle)
        || $0.path.localizedStandardContains(needle)
    }
  }

  func reset() {
    revision += 1
    cookies = []
    selectedID = nil
    search = ""
    failure = nil
    loading = false
    saving = false
    target = nil
    store = nil
  }

  func configure(store: (any ShaarCookieStore)?, target: SiteControlTarget) {
    self.store = store
    guard self.target != target else { return }
    revision += 1
    self.target = target
    cookies = []
    selectedID = nil
    search = ""
    failure = nil
    loading = false
    saving = false
  }

  func refresh() async {
    guard let store, let target else {
      failure = ShellL10n.string("Individual cookies are unavailable for this site")
      return
    }
    let revision = revision
    loading = true
    defer { if revision == self.revision { loading = false } }
    do {
      let updated = try await store.siteCookies(for: target)
      guard revision == self.revision else { return }
      cookies = updated.sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
      if !cookies.contains(where: { $0.id == selectedID }) { selectedID = nil }
      failure = nil
    } catch {
      if revision == self.revision {
        failure = ShellL10n.string("Individual cookies are unavailable for this site")
      }
    }
  }

  func save(value: String, secure: Bool, httpOnly: Bool, sameSite: ShaarCookieSameSite) async {
    guard let store, let target, let selected, !saving else { return }
    let revision = revision
    saving = true
    defer { if revision == self.revision { saving = false } }
    do {
      try await store.setSiteCookie(
        selected, value: value, secure: secure, httpOnly: httpOnly,
        sameSite: sameSite, for: target)
      guard revision == self.revision else { return }
      await refresh()
    } catch { if revision == self.revision { failure = error.localizedDescription } }
  }

  func deleteSelected() async {
    guard let store, let target, let selected, !saving else { return }
    let revision = revision
    saving = true
    defer { if revision == self.revision { saving = false } }
    do {
      try await store.deleteSiteCookie(selected, for: target)
      guard revision == self.revision else { return }
      selectedID = nil
      await refresh()
    } catch { if revision == self.revision { failure = error.localizedDescription } }
  }
}
