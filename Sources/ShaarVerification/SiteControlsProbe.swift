// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Drives the site control center against an authored loopback page in its own site, so clearing
/// cookies and storage never touches other probes' accounts.
@MainActor
final class SiteControlsProbe {
  private static let spaceName = "Site controls"
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
  private var previewWindow: NSWindow?

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run() async throws -> [String] {
    do {
      try await exercise()
      try report(error: nil)
      return checks
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise() async throws {
    let returnSpace = store.session.selectedSpaceID
    let tab = try await openFixtureSpace()
    let target = try require(engine.siteControlTarget, "site controls target the selected page")
    try expect(
      target.tabID == tab && target.origin?.hasPrefix("http://site-controls.localhost") == true,
      "site controls target the selected tab's http origin in its owning profile")
    let model = SiteControlsModel(target: target, backend: engine)
    try expect(
      model.security == .notSecure && !model.hasCertificate,
      "an http page reads as not secure without a certificate to show")
    try await checkPermissions(model)
    try await checkAutoPictureInPicture(model)
    try await capture(model)
    try await checkActions(tab)
    try await removeFixtureSpace(returningTo: returnSpace)
  }

  /// Leaves no extra live tab behind, so the restart phase restores the same load it would
  /// without this probe. Site settings stay in the profile, so persistence is still checked.
  private func removeFixtureSpace(returningTo returnSpace: UUID) async throws {
    let space = try require(
      store.session.spaces.first { $0.name == Self.spaceName }, "fixture space exists")
    let tabs = Set(space.tabs.map(\.id))
    store.perform(.space(returnSpace))
    try expect(store.removeSpace(space.id), "the site controls fixture space can be removed")
    for _ in 0..<Int(50 * ProbeTimeout.scale) {
      if engine.liveTabs.isDisjoint(with: tabs) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    try expect(
      engine.liveTabs.isDisjoint(with: tabs), "removing the fixture space closes its live tab")
  }

  private func openFixtureSpace() async throws -> UUID {
    if let space = store.session.spaces.first(where: { $0.name == Self.spaceName }) {
      store.perform(.space(space.id))
    } else {
      let profile = store.session.spaces[0].profileID
      guard store.createSpace(name: Self.spaceName, sharingProfile: profile, tint: .forest) else {
        throw SiteControlsProbeFailure("Could not create the site controls space.")
      }
      var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
      components.host = "site-controls.localhost"
      components.path = "/site-controls"
      components.query = nil
      store.perform(.open(components.url!))
    }
    let tab = try require(store.session.selectedSpace.selectedTabID, "fixture tab is selected")
    _ = try await document(tab)
    return tab
  }

  private func checkPermissions(_ model: SiteControlsModel) async throws {
    await model.load()
    try expect(
      model.failure == nil && Set(model.permissionValues.keys) == Set(SitePermission.allCases),
      "every site permission reads from Chromium's content settings for the profile")
    if phase == "restart" {
      try expect(
        model.isAllowed(.popups), "a site permission changed before restart is still in effect")
    }
    await model.setPermission(.popups, allowed: phase == "initial")
    await model.setPermission(.camera, allowed: false)
    let reloaded = SiteControlsModel(target: model.target, backend: engine)
    await reloaded.load()
    try expect(
      reloaded.isAllowed(.popups) == (phase == "initial")
        && reloaded.permissionValues[.camera] == .block,
      "permission toggles are saved to Chromium and read back for the site")
    try await engine.runtime.setSiteSetting(
      "camera", value: "default", origin: model.target.origin!,
      profileID: model.target.profileID.uuidString)
    await reloaded.load()
    try expect(
      reloaded.permissionValues[.camera] == .ask,
      "removing a site's camera exception restores Chromium's ask default")
  }

  /// The toggle drives the playback feature's per-site setting rather than a store of its own.
  private func checkAutoPictureInPicture(_ model: SiteControlsModel) async throws {
    let target = model.target
    let other = store.session.spaces[0].selectedTab!.url
    await model.setPermission(.autoPictureInPicture, allowed: false)
    let reloaded = SiteControlsModel(target: target, backend: engine)
    await reloaded.load()
    try expect(
      !store.automaticPictureInPictureAllowed(for: target.url, profileID: target.profileID)
        && reloaded.permissionValues[.autoPictureInPicture] == .block
        && store.automaticPictureInPictureAllowed(for: other, profileID: target.profileID),
      "turning off automatic picture-in-picture saves it for this site only")
    await model.setPermission(.autoPictureInPicture, allowed: true)
    try expect(
      store.automaticPictureInPictureAllowed(for: target.url, profileID: target.profileID),
      "turning automatic picture-in-picture back on allows it again for the site")
  }

  private func checkActions(_ tab: UUID) async throws {
    try await seed(tab)
    var page = try await run(.clearCookiesAndReload, tab)
    try expect(
      page["cookie"] as? String == "" && page["local"] as? String == "kept",
      "Clear Cookies and Reload deletes the page's cookies but keeps its storage")
    try await seed(tab)
    page = try await run(.clearSiteData, tab, reloadAfterwards: true)
    try expect(
      page["cookie"] as? String == "" && page["local"] is NSNull,
      "Clear All Site Data deletes the site's cookies and storage")
    try await seed(tab)
    page = try await run(.hardReload, tab)
    try expect(page["cookie"] as? String == "siteControl=kept", "Hard Reload keeps site data")
    page = try await run(.clearCacheAndReload, tab)
    try expect(
      page["cookie"] as? String == "siteControl=kept",
      "Clear Cache and Reload empties the cache and keeps cookies")
    page = try await run(.restartPage, tab)
    try expect(
      page["cookie"] as? String == "siteControl=kept" && store.rendererFailures[tab] == nil
        && store.session.selectedSpace.selectedTabID == tab,
      "Restart Page reloads the same tab in a new renderer without a renderer failure")
    page = try await run(.reload, tab)
    try expect(page["fixture"] as? String == "v1", "Reload loads the page again")
  }

  /// Runs an action through the panel model and returns the replacement document.
  private func run(_ action: SiteAction, _ tab: UUID, reloadAfterwards: Bool = false)
    async throws -> [String: Any]
  {
    let before = try await document(tab)
    let target = try require(engine.siteControlTarget, "\(action.title) has a target")
    let model = SiteControlsModel(target: target, backend: engine)
    let finished = await model.perform(action)
    try expect(finished && model.failure == nil, "\(action.title) finishes without an error")
    if reloadAfterwards { store.reloadCurrentPage() }
    for _ in 0..<100 {
      let page = try await document(tab)
      if page["instance"] as? String != before["instance"] as? String { return page }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw SiteControlsProbeFailure("\(action.title) did not load a new document.")
  }

  private func seed(_ tab: UUID) async throws {
    _ = await evaluate(
      tab,
      """
      (()=>{document.cookie='siteControl=kept; Path=/; Max-Age=600; SameSite=Lax';
        localStorage.setItem('siteControl','kept');return {seeded:true};})()
      """)
  }

  private func document(_ tab: UUID) async throws -> [String: Any] {
    for _ in 0..<100 {
      if engine.pages[tab]?.loading == false,
        let value = await evaluate(
          tab,
          "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('siteControl')})"
        ),
        value["fixture"] as? String == "v1"
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw SiteControlsProbeFailure("The site controls fixture page was not ready.")
  }

  private func evaluate(_ tab: UUID, _ expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      engine.runtime.evaluate(inTabID: tab.uuidString, script: expression) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func capture(_ model: SiteControlsModel) async throws {
    let extensions = ExtensionManagerModel.shared(
      runtime: engine.runtime, preferences: store.preferences, profileID: model.target.profileID)
    let actions = SiteControlsPanelActions(
      runExtension: { _ in }, addExtensions: {}, showCertificate: {}, showDeveloperTools: {},
      close: {})
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
      let panel = SiteControlsPanel(
        model: model, extensions: extensions, profileName: store.profileName, actions: actions
      )
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)
      let host = NSHostingView(rootView: panel)
      let size = host.fittingSize
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      window.contentView = host
      previewWindow = window
      try await Task.sleep(for: .milliseconds(150))
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw SiteControlsProbeFailure("The site control center could not render.")
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SiteControlsProbeFailure("The site control center could not encode.")
      }
      try png.write(
        to: root.appending(path: "\(phase)-site-controls-\(name).png"), options: .atomic)
    }
    checks.append("site control center renders offscreen with live engine state")
  }

  private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw SiteControlsProbeFailure(message) }
    return value
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SiteControlsProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "phase": phase, "checks": checks,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Site permissions, data clearing, reload modes and renderer restart on an authored loopback page in a disposable profile. HTTPS certificates and the native certificate sheet are not exercised.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-site-controls.json"), options: .atomic)
  }
}

private struct SiteControlsProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
