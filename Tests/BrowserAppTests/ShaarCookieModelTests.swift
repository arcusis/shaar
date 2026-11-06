// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

@MainActor private final class CookieFixture: ShaarCookieStore {
  var items: [ShaarSiteCookie] = []
  var savedValue: String?
  var deletedName: String?

  func siteCookies(for target: SiteControlTarget) async throws -> [ShaarSiteCookie] { items }
  func setSiteCookie(
    _ cookie: ShaarSiteCookie, value: String, secure: Bool, httpOnly: Bool,
    sameSite: ShaarCookieSameSite, for target: SiteControlTarget
  ) async throws {
    savedValue = value
    items = items.compactMap { row in
      guard row.id == cookie.id else { return row }
      var payload = row.identity
      payload["value"] = value
      payload["secure"] = secure
      payload["httpOnly"] = httpOnly
      payload["sameSite"] = sameSite.rawValue
      payload["expiresUnixMs"] = NSNull()
      return ShaarSiteCookie(dictionary: payload)
    }
  }
  func deleteSiteCookie(_ cookie: ShaarSiteCookie, for target: SiteControlTarget) async throws {
    deletedName = cookie.name
    items.removeAll { $0.id == cookie.id }
  }
}

@Suite @MainActor struct ShaarCookieModelTests {
  @Test func productionWithoutSiteDataRouteShowsNoFixtureCookies() async {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let model = ShaarCookieModel()
    model.configure(store: nil, target: target)
    await model.refresh()
    #expect(model.cookies.isEmpty)
    #expect(model.failure != nil)
  }

  @Test func readsFiltersEditsDeletesAndResetsForNewPage() async throws {
    let store = CookieFixture()
    store.items = [
      try #require(
        ShaarSiteCookie(dictionary: [
          "name": "session", "value": "old", "domain": "example.com", "path": "/",
          "secure": true, "httpOnly": true, "sameSite": "Lax", "expiresUnixMs": NSNull(),
          "partitionSite": NSNull(), "partitionCrossSite": NSNull(),
          "sourceScheme": 2, "sourcePort": 443,
        ]))
    ]
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/")!)
    let model = ShaarCookieModel()
    model.configure(store: store, target: target)
    await model.refresh()
    #expect(model.cookies.count == 1)
    model.search = "example"
    #expect(model.visibleCookies.count == 1)
    model.selectedID = model.cookies[0].id
    await model.save(value: "new", secure: true, httpOnly: false, sameSite: .strict)
    #expect(store.savedValue == "new")
    #expect(model.cookies.first?.value == "new")
    await model.deleteSelected()
    #expect(store.deletedName == "session")
    #expect(model.cookies.isEmpty)
    model.configure(
      store: store,
      target: SiteControlTarget(
        tabID: UUID(), profileID: target.profileID,
        url: URL(string: "https://other.example/")!))
    #expect(model.search.isEmpty && model.selectedID == nil)
  }
}
