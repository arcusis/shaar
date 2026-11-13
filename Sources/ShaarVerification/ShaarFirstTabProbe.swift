// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI

@testable import ArcusisBrowser

/// Exercises the production backend selector and browser host without showing a window.
@MainActor
final class ShaarFirstTabProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let tabID: UUID
  private let profileID: UUID
  private let checksInspector: Bool
  private let checksFavicon: Bool
  private let restoresFavicon: Bool
  private let systemQuit: Bool
  private let inspectorFixture: URL?
  private var inspectorChecks: [String] = []
  private let checksCoreRoutes: Bool
  private let checksExtensions: Bool
  private let checksPrivatePrivacy: Bool
  private let output: URL
  private let dataRoot: URL
  private let pageURL: URL
  private var faviconObserved = false
  private var faviconCacheRestored = false
  private var inactiveFaviconObserved = false
  private var awaitingFavoriteIcon = false
  private var favoriteFaviconCached = false
  private var restoredPinIcon = false
  private var restoredFavoriteIcon = false
  private var restoredPinFromCache = false
  private var restoredFavoriteDormant = false
  private var sidebarIconPixels = 0
  private var finished = false
  private var passed = false
  private var navigationCommitted = false
  private var coreChecksStarted = false
  private var coreRoutesObserved = false
  private var extensionListObserved = false
  private var privatePolicyStatus: [AnyHashable: Any] = [:]
  private var privatePolicyChecks: [String: Bool] = [:]

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
      else { throw Failure("Missing \(flag).") }
      return arguments[index + 1]
    }

    let framework = URL(filePath: try value(after: "--probe-framework"))
    let executable = Bundle.main.executableURL
    guard let executable,
      Self.isBundledFramework(framework, for: executable)
    else {
      throw Failure(
        "The first-tab probe requires Shaar Verification.app and its bundled Chromium framework. Build it with scripts/bundle-app.sh --with-engine --verification."
      )
    }
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    checksInspector = arguments.contains("--probe-shaar-inspector")
    checksFavicon = arguments.contains("--probe-favicon-url")
    restoresFavicon = arguments.contains("--probe-favicon-restore")
    if checksFavicon {
      guard let iconPage = URL(string: try value(after: "--probe-favicon-url")),
        iconPage.scheme == "http", iconPage.host == "127.0.0.1"
      else { throw Failure("Favicon probe requires an authored loopback page.") }
      pageURL = iconPage
    } else {
      pageURL = URL(string: "https://example.com")!
    }
    systemQuit = arguments.contains("--probe-system-quit")
    if checksInspector {
      guard let url = URL(string: try value(after: "--probe-inspector-url")),
        url.scheme == "http", url.host == "127.0.0.1"
      else { throw Failure("Inspector probe requires an authored loopback fixture.") }
      inspectorFixture = url
    } else {
      inspectorFixture = nil
    }
    checksCoreRoutes = arguments.contains("--probe-shaar-core-routes")
    checksExtensions = arguments.contains("--probe-shaar-extensions")
    checksPrivatePrivacy = arguments.contains("--probe-shaar-private-privacy")
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    if checksFavicon {
      workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: dataRoot.appending(path: "workspace.json"),
          legacySessionURL: dataRoot.appending(path: "session.json")),
        faviconCache: FaviconCache(directory: dataRoot.appending(path: "favicons")))
    } else {
      workspace = try BrowserWorkspaceStore()
    }
    guard let window = workspace.workspace.windows.first,
      let store = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    if restoresFavicon {
      guard
        let id = store.session.selectedSpace.tabs.first(where: \.isPinned)?.id
          ?? store.session.selectedSpace.selectedTabID
      else { throw Failure("The saved workspace has no tab to restore.") }
      tabID = id
      guard let owner = store.session.profileID(forTabID: id) else {
        throw Failure("The restored tab has no profile.")
      }
      profileID = owner
    } else {
      store.perform(.open(pageURL))
      guard let id = store.session.selectedSpace.selectedTabID else {
        throw Failure("The fresh workspace did not create its first tab.")
      }
      tabID = id
      guard let owner = store.session.profileID(forTabID: id) else {
        throw Failure("The first tab has no profile.")
      }
      profileID = owner
      if checksFavicon { store.togglePin(id) }
    }
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let probe = try ShaarFirstTabProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(
        Data("Shaar first-tab probe: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  static func isBundledFramework(_ framework: URL, for executable: URL) -> Bool {
    let executable = executable.resolvingSymlinksInPath().standardizedFileURL
    let macOS = executable.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
      app.pathExtension == "app"
    else { return false }
    let expected = contents.appending(path: "Frameworks/Chromium Framework.framework")
    return framework.resolvingSymlinksInPath().standardizedFileURL.path
      == expected.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private var probeTimeout: TimeInterval {
    if checksInspector { return 45 }
    if checksFavicon { return 30 }
    return 20
  }

  private func run() -> Int32 {
    let previousCommitted = runtime.onDocumentCommitted
    runtime.onDocumentCommitted = { [weak self] id, profile in
      previousCommitted?(id, profile)
      guard let self, id == self.tabID.uuidString else { return }
      self.navigationCommitted = true
      DispatchQueue.main.async { [weak self] in self?.checkTab() }
    }
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
        if self.restoresFavicon {
          self.checkRestoredFavicons()
        } else {
          self.checkTab()
        }
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
      }
    }
    // The optional session diagnostic covers two scopes and a bounded renderer capture.
    DispatchQueue.main.asyncAfter(deadline: .now() + probeTimeout) { [weak self] in
      self?.finish(error: "Timed out waiting for a native Shaar tab.")
    }
    let result = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func checkTab() {
    guard !finished else { return }
    if awaitingFavoriteIcon {
      checkFavoriteIcon()
      return
    }
    let tab = tabID.uuidString
    if let view = runtime.view(forTabID: tab),
      let windowID = runtime.windowID(forTabID: tab),
      let window = runtime.window(forID: windowID),
      host.contexts.values.contains(where: { $0.engine.pages[tabID] != nil }),
      workspace.stores.values.contains(where: {
        Self.matchesRequestedURL($0.session.selectedSpace.selectedTab?.url, requested: pageURL)
      }),
      navigationCommitted,
      !window.isVisible, NSApp.windows.allSatisfy({ !$0.isVisible })
    {
      if checksFavicon {
        guard
          runtime.favicon(
            forTabID: tab, profileID: profileID.uuidString, windowID: windowID) != nil
        else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.checkTab()
          }
          return
        }
        faviconObserved = true
        guard let store = workspace.stores.values.first,
          let pinID = workspace.workspace.windows.first?.pins.first(where: {
            $0.tabID == tabID
          })?.pinID,
          FaviconCache(directory: dataRoot.appending(path: "favicons"))
            .icon(for: pinID, profileID: profileID) != nil
        else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.checkTab()
          }
          return
        }
        faviconCacheRestored = true
        store.perform(
          .open(pageURL.appending(queryItems: [URLQueryItem(name: "inactive", value: "1")])))
        inactiveFaviconObserved =
          store.session.selectedSpace.selectedTabID != tabID
          && runtime.favicon(
            forTabID: tab, profileID: profileID.uuidString, windowID: windowID) != nil
        guard inactiveFaviconObserved else {
          finish(error: "An inactive native tab lost its favicon.")
          return
        }
        awaitingFavoriteIcon = true
        checkFavoriteIcon()
        return
      }
      if checksInspector {
        checkInspector(tabID: tab, nativeView: view)
      } else if checksExtensions {
        checkExtensionRoute(tabID: tab, nativeView: view)
      } else if checksCoreRoutes {
        checkCoreRoutes(tabID: tab, nativeView: view)
      } else if checksPrivatePrivacy {
        checkPrivatePrivacy(tabID: tab, nativeView: view)
      } else {
        finish(tabID: tab, nativeView: view)
      }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.checkTab()
    }
  }

  private func checkInspector(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    Task { @MainActor in
      do {
        guard let inspectorFixture,
          let context = host.contexts.values.first(where: { $0.engine.pages[self.tabID] != nil })
        else { throw Failure("Inspector has no owning browser context.") }
        try await ShaarInspectorSessionProbe(
          runtime: runtime, engine: context.engine, profileID: profileID, fixture: inspectorFixture
        ).run { inspectorChecks.append($0) }
        finish(tabID: tabID, nativeView: nativeView)
      } catch {
        finish(error: "Inspector session check failed: \(error)")
      }
    }
  }

  private func checkPrivatePrivacy(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    let contextID = UUID().uuidString
    runtime.createPrivateContextID(contextID, sourceProfileID: profileID.uuidString) {
      [weak self] opened, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard opened, error == nil else {
          self.finish(
            error: "Shaar private context could not be created: \(String(describing: error)).")
          return
        }
        self.privatePolicyStatus = await self.runtime.privatePrivacyStatus(forContextID: contextID)
        self.privatePolicyChecks = PrivatePrivacyEvidence.engineStatus(self.privatePolicyStatus)
        let released = self.runtime.releasePrivateContextID(contextID)
        let failed = self.privatePolicyChecks.filter { !$0.value }.keys.sorted()
        guard released, failed.isEmpty else {
          self.finish(error: "Shaar private policies failed: \(failed.joined(separator: ", ")).")
          return
        }
        self.finish(tabID: tabID, nativeView: nativeView)
      }
    }
  }

  private func checkExtensionRoute(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    let owner = profileID.uuidString
    guard runtime.extensionsDirectory(forProfileID: owner) != nil else {
      finish(error: "Shaar did not provide the profile extension directory.")
      return
    }
    runtime.manageExtensions(
      forProfileID: owner, operation: .list, extensionID: nil, enabled: false
    ) { [weak self] json in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let json, let data = json.data(using: .utf8),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          Set(rows.compactMap { $0["id"] as? String }).count == rows.count
        else {
          self.finish(error: "Shaar extension list failed for the owning profile.")
          return
        }
        self.extensionListObserved = true
        self.finish(tabID: tabID, nativeView: nativeView)
      }
    }
  }

  private func checkCoreRoutes(tabID: String, nativeView: NSView) {
    guard !coreChecksStarted else { return }
    coreChecksStarted = true
    let owner = profileID.uuidString
    runtime.bookmarks(forProfileID: owner) { [weak self] tree, error in
      guard let self else { return }
      guard error == nil, tree?["bar"] != nil, tree?["other"] != nil else {
        self.finish(error: "Shaar bookmarks tree failed: \(String(describing: error))")
        return
      }
      self.runtime.history(forProfileID: owner, limit: 20) { [weak self] rows, error in
        guard let self else { return }
        guard error == nil, rows != nil else {
          self.finish(error: "Shaar history query failed: \(String(describing: error))")
          return
        }
        let token = UUID().uuidString
        guard
          self.runtime.find(
            inTabID: tabID, profileID: owner, requestID: token, text: "Example", forward: true)
        else {
          self.finish(error: "Shaar find request was rejected.")
          return
        }
        self.runtime.stopFinding(inTabID: tabID)
        self.coreRoutesObserved = true
        DispatchQueue.main.async { [weak self] in
          self?.finish(tabID: tabID, nativeView: nativeView)
        }
      }
    }
  }

  private func checkFavoriteIcon() {
    guard let store = workspace.stores.values.first,
      let selected = store.session.selectedSpace.selectedTabID, selected != tabID,
      let windowID = runtime.windowID(forTabID: selected.uuidString),
      runtime.favicon(
        forTabID: selected.uuidString, profileID: profileID.uuidString, windowID: windowID) != nil
    else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.checkTab() }
      return
    }
    let space = store.session.selectedSpaceID
    guard
      store.acceptFavoritesDrop(
        .tab(sessionID: store.dragSessionID, sourceSpaceID: space, tabID: selected))
    else {
      finish(error: "Could not move the loaded page to Favorites.")
      return
    }
    guard let favorite = store.session.favorites.first,
      FaviconCache(directory: dataRoot.appending(path: "favicons"))
        .icon(for: favorite.id, profileID: profileID) != nil
    else {
      finish(error: "Moving a page to Favorites dropped its icon.")
      return
    }
    favoriteFaviconCached = true
    store.perform(.tab(space: space, tab: tabID))
    do {
      try workspace.flushSaves()
    } catch {
      finish(error: "Could not save the workspace: \(error)")
      return
    }
    guard let view = runtime.view(forTabID: tabID.uuidString) else {
      finish(error: "The pinned tab lost its view before quit.")
      return
    }
    finish(tabID: tabID.uuidString, nativeView: view)
  }

  private func checkRestoredFavicons() {
    guard !finished else { return }
    do {
      guard let store = workspace.stores.values.first,
        let pinned = store.session.selectedSpace.tabs.first(where: \.isPinned),
        let profile = store.session.profileID(forTabID: pinned.id),
        let favorite = store.session.favorites.first,
        let favoriteTab = store.session.favoritePage(for: favorite.id)?.tab.id,
        let pinID = workspace.workspace.windows.first?.pins.first(where: {
          $0.tabID == pinned.id
        })?.pinID
      else {
        finish(error: "Restarted sidebar is missing a saved pin or Favorite.")
        return
      }
      let cache = FaviconCache(directory: dataRoot.appending(path: "favicons"))
      guard let pinIcon = cache.icon(for: pinID, profileID: profile),
        let favoriteIcon = cache.icon(for: favorite.id, profileID: favorite.profileID)
      else {
        finish(error: "Restarted sidebar is missing a saved pin or Favorite icon.")
        return
      }
      let engine = host.contexts.values.first?.engine
      restoredPinFromCache = engine?.favicons[pinned.id] == nil
      guard restoredPinFromCache else {
        finish(error: "The restored pin icon came from a live load, not the cache.")
        return
      }
      let pixels = try renderedSidebarIconPixels(matching: [pinIcon, favoriteIcon])
      sidebarIconPixels = pixels
      restoredPinIcon = true
      restoredFavoriteIcon = true
      restoredFavoriteDormant = engine?.liveTabs.contains(favoriteTab) != true
      guard restoredFavoriteDormant else {
        finish(error: "The restored Favorite was opened before its saved icon could be shown.")
        return
      }
      guard pixels >= Self.minimumIconPixels, pixels <= Self.maximumIconPixels else {
        let sample = [pinIcon, favoriteIcon].compactMap(Self.centerColor(of:)).map {
          String(format: "%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent)
        }.joined(separator: " ")
        finish(error: "Restarted sidebar drew \(pixels) favicon pixels (icon \(sample)).")
        return
      }
      guard NSApp.windows.allSatisfy({ !$0.isVisible }) else {
        finish(error: "A window was visible during the favicon restore.")
        return
      }
      let nativeID = host.contexts.values.first?.nativeID ?? ""
      let view =
        runtime.view(forTabID: pinned.id.uuidString)
        ?? runtime.window(forID: nativeID)?.contentView
      finish(tabID: pinned.id.uuidString, nativeView: view)
    } catch {
      finish(error: "Favicon restore failed: \(error.localizedDescription)")
    }
  }

  private func renderedSidebarIconPixels(matching images: [NSImage]) throws -> Int {
    guard let store = workspace.stores.values.first else {
      throw Failure("Restored workspace has no sidebar.")
    }
    let size = NSSize(width: 240, height: 520)
    let sidebar = NSHostingView(
      rootView: BrowserSidebar(store: store)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = sidebar
    sidebar.frame = NSRect(origin: .zero, size: size)
    defer { window.close() }
    sidebar.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    sidebar.layoutSubtreeIfNeeded()
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw Failure("Could not render the restored sidebar.") }
    bitmap.size = size
    sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
    if let png = bitmap.representation(using: .png, properties: [:]) {
      try png.write(
        to: output.deletingLastPathComponent().appending(path: "favicon-sidebar.png"),
        options: .atomic)
    }
    return Self.iconPixelCount(in: bitmap, matching: images)
  }

  /// The 16-point pin and 22-point Favorite are 256 and 484 pixels. The band rejects
  /// a handful of accent pixels and a large tinted region.
  private static let minimumIconPixels = 640
  private static let maximumIconPixels = 960
  private static let iconColorDistance = 0.05

  private static func iconPixelCount(
    in bitmap: NSBitmapImageRep, matching images: [NSImage]
  ) -> Int {
    let targets = images.compactMap { centerColor(of: $0) }
    var count = 0
    for x in 0..<bitmap.pixelsWide {
      for y in 0..<bitmap.pixelsHigh {
        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let matched = targets.contains { target in
          max(
            abs(pixel.redComponent - target.redComponent),
            abs(pixel.greenComponent - target.greenComponent),
            abs(pixel.blueComponent - target.blueComponent)) < Self.iconColorDistance
        }
        if matched { count += 1 }
      }
    }
    return count
  }

  /// Samples the icon the same way the sidebar bitmap is captured, so the comparison
  /// is not shifted by a different color space.
  private static func centerColor(of image: NSImage) -> NSColor? {
    let side = 16
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    bitmap.size = NSSize(width: CGFloat(side), height: CGFloat(side))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.colorAt(x: side / 2, y: side / 2)?.usingColorSpace(.sRGB)
  }

  static func matchesRequestedURL(_ actual: URL?, requested: URL) -> Bool {
    guard let actual, actual.scheme == requested.scheme, actual.host == requested.host,
      effectivePort(actual) == effectivePort(requested),
      actual.query == requested.query, actual.fragment == requested.fragment
    else { return false }
    return actual.path == requested.path || (actual.path == "/" && requested.path.isEmpty)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil)
  }

  private func finish(tabID: String? = nil, nativeView: NSView? = nil, error: String? = nil) {
    guard !finished else { return }
    finished = true
    passed = tabID != nil && nativeView != nil && error == nil
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "shaar-first-tab",
      "backend": "shaar",
      "passed": passed,
      "tabID": tabID ?? "",
      "nativeView": nativeView != nil,
      "navigationObserved": navigationCommitted,
      "faviconObserved": faviconObserved,
      "faviconCacheRestored": faviconCacheRestored,
      "inactiveFaviconObserved": inactiveFaviconObserved,
      "favoriteFaviconCached": favoriteFaviconCached,
      "restoredPinIcon": restoredPinIcon,
      "restoredFavoriteIcon": restoredFavoriteIcon,
      "restoredPinFromCache": restoredPinFromCache,
      "restoredFavoriteDormant": restoredFavoriteDormant,
      "sidebarIconPixels": sidebarIconPixels,
      "coreRoutesObserved": coreRoutesObserved,
      "inspectorChecks": inspectorChecks,
      "extensionListObserved": extensionListObserved,
      "privatePolicyStatus": privatePolicyStatus,
      "privatePolicyChecks": privatePolicyChecks,
      "requestedURL": pageURL.absoluteString,
      "allWindowsHidden": NSApp.windows.allSatisfy { !$0.isVisible },
      "systemQuitRequested": systemQuit,
      "error": error ?? "",
    ]
    do {
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output, options: .atomic)
    } catch {
      passed = false
      FileHandle.standardError.write(Data("Shaar first-tab report failed: \(error)\n".utf8))
    }
    if !passed {
      host.events.quit()
      return
    }
    if checksFavicon || restoresFavicon {
      // Profile load refreshes bookmarks on this window. Close after that submit.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self else { return }
        self.closeProbeWindows()
        self.quitProbe()
      }
      return
    }
    // Let the normal engine quit path tear down this single probe window. Closing it
    // separately can race profile refresh submissions still in flight on older engines.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.quitProbe()
    }
  }

  private func closeProbeWindows() {
    for context in host.contexts.values {
      _ = runtime.closeWindowID(context.nativeID)
    }
  }

  private func quitProbe() {
    if systemQuit {
      NSApp.terminate(nil)
    } else {
      host.events.quit()
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
