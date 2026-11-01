// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge.Verification
import SwiftUI

@testable import ArcusisBrowser

/// Real public pages, disposable profiles, and the production hidden-window host.
/// Chromium's remote surface is captured through the existing in-process probe API and
/// inserted at its exact native viewport for bitmap rendering, including native overlays.
@MainActor
final class MarketingScreenshots {
  private let root: URL
  private let runtime: ARCChromiumRuntime
  private var host: NativeBrowserHost?
  private var context: NativeBrowserContext!
  private var finished = false
  private var passed = false
  private var images: [[String: Any]] = []
  private var skipped: [[String: String]] = []
  private var installed: [[String: Any]] = []
  private var extensionManager: ExtensionManagerModel?
  private let size = NSSize(width: 1440, height: 960)
  private let scale: CGFloat = 2

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  private init(root: URL) throws {
    self.root = root
    guard let frameworks = Bundle.main.privateFrameworksURL else {
      throw Failure("Run the bundled verification executable.")
    }
    runtime = try ARCChromiumRuntime(
      frameworkURL: frameworks.appending(path: "Chromium Framework.framework"))
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      guard let index = arguments.firstIndex(of: "--probe-data-dir"),
        arguments.indices.contains(index + 1)
      else { throw Failure("Missing --probe-data-dir.") }
      let root = URL(filePath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
      let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        .resolvingSymlinksInPath()
      guard root.path.hasPrefix(temporary.path + "/"),
        try String(contentsOf: root.appending(path: ".arcusis-probe"), encoding: .utf8)
          == "arcusis-engine-probe-v1\n",
        !FileManager.default.fileExists(atPath: root.appending(path: "Chromium").path)
      else { throw Failure("Capture requires a fresh marked temporary directory.") }
      let probe = try MarketingScreenshots(root: root)
      probe.runtime.onReady = {
        Task {
          do { try await probe.captureAll() } catch { probe.finish(error) }
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
        probe.finish(Failure("Marketing capture timed out."))
      }
      let code = probe.runtime.run(
        withDataDirectory: root.appending(path: "Chromium"), testing: true)
      return probe.passed ? code : 1
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func seed() throws -> BrowserSession {
    let profiles = [
      BrowserProfile(name: "Work", tint: .forest, symbol: "briefcase"),
      BrowserProfile(name: "Personal", customRGB: SpaceRGBColor(hex: "#DCA34B"), symbol: "person"),
    ]
    func tab(_ url: String, _ title: String, pinned: Bool = false) -> BrowserTab {
      BrowserTab(url: URL(string: url)!, title: title, isPinned: pinned)
    }
    let spaces = [
      BrowserSpace(
        profileID: profiles[0].id, name: "Work", symbol: "briefcase", tint: .forest,
        tabs: [
          tab("https://github.com/arcusis/shaar", "Shaar", pinned: true),
          tab("https://developer.apple.com/documentation/swiftui", "SwiftUI", pinned: true),
          tab("https://developers.cloudflare.com/workers/", "Cloudflare Workers"),
          tab("https://news.ycombinator.com/", "Hacker News"),
        ]),
      BrowserSpace(
        profileID: profiles[1].id, name: "Personal", symbol: "house", tint: .rose,
        customRGB: SpaceRGBColor(hex: "#DCA34B"),
        tabs: [
          tab("https://en.wikipedia.org/wiki/Lisbon", "Lisbon", pinned: true),
          tab("https://music.youtube.com/", "YouTube Music", pinned: true),
          tab("https://en.wikipedia.org/wiki/Portugal", "Portugal"),
        ]),
      BrowserSpace(
        profileID: profiles[0].id, name: "Side project", symbol: "hammer", tint: .ocean,
        tabs: [
          tab("https://developers.cloudflare.com/workers/", "Cloudflare Workers", pinned: true),
          tab("https://docs.swift.org/latest/documentation/", "Swift documentation"),
          tab("https://github.com/arcusis/shaar/issues", "Shaar issues"),
        ]),
    ]
    return try BrowserSession(profiles: profiles, spaces: spaces, selectedSpaceID: spaces[0].id)
  }

  private func captureAll() async throws {
    NSApp.appearance = NSAppearance(named: .aqua)
    let workspace = try BrowserWorkspaceStore(initialSession: seed())
    let host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe,
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1200)] })
    self.host = host
    try host.restore()
    guard let context = host.contexts.values.first else { throw Failure("Hidden host missing.") }
    self.context = context
    context.window.appearance = NSAppearance(named: .aqua)
    context.window.setFrame(NSRect(origin: .zero, size: size), display: false)
    try await settle()

    // Visit every seeded page: titles, favicons and history come from the real engine.
    for space in context.store.session.spaces {
      for tab in space.tabs {
        print("Loading \(tab.url.absoluteString)")
        fflush(stdout)
        context.store.perform(.tab(space: space.id, tab: tab.id))
        _ = try await loaded(tab.id, expected: tab.url)
      }
    }
    try await select(space: "Work")
    try await capture("hero.png", "Work Space with the public Shaar GitHub repository.")
    try await select(space: "Personal")
    try await capture("spaces.png", "Amber Personal Space with Wikipedia's Lisbon article.")
    try await select(space: "Work")

    // Create real history distinct from the open SwiftUI tab, then close the visit.
    context.store.perform(.open(URL(string: "https://www.swift.org/")!))
    let historyTab = context.store.session.selectedPage!.tab.id
    _ = try await loaded(historyTab, expected: URL(string: "https://www.swift.org/")!)
    context.store.closeTab(historyTab)
    try await select(space: "Work")
    let profile = context.store.session.selectedSpace.profileID
    context.store.library.refresh(profile, section: .history)
    try await wait("real launcher history") {
      self.context.store.library.history[profile]?.contains { $0.address.contains("swift.org") }
        == true
    }
    context.store.showCommand()
    context.store.commandQuery = "swift"
    let results = context.store.commandSections.flatMap(\.results)
    guard results.contains(where: { if case .tab = $0.action { true } else { false } }),
      results.contains(where: { if case .history = $0.action { true } else { false } }),
      results.contains(where: { $0.isOpen })
    else {
      throw Failure("Launcher must include tabs, history, and Open results.")
    }
    try await capture(
      "command-t.png", "Command-T searching swift across real tabs and browsing history.")
    context.store.dismissCommand()
    try await settle()

    guard let target = context.engine.siteControlTarget else { throw Failure("No HTTPS target.") }
    let model = SiteControlsModel(target: target, backend: context.engine)
    await model.load()
    guard model.failure == nil, model.security == .secure else {
      throw Failure("HTTPS site controls did not report a secure page.")
    }
    let panel = SiteControlsPanel(
      model: model,
      extensions: ExtensionManagerModel.shared(
        runtime: runtime, preferences: context.store.preferences, profileID: profile),
      profileName: context.store.profileName,
      actions: SiteControlsPanelActions(
        runExtension: { _ in }, addExtensions: {}, showCertificate: {}, close: {})
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    .environment(\.colorScheme, .light)
    // Keep the control center inside the SwiftUI tree, like the launcher overlay.
    // An unrelated AppKit child of NSHostingView is omitted by its bitmap renderer.
    let panelHost = NSHostingView(
      rootView: BrowserWindow(store: context.store)
        .overlay(alignment: .topTrailing) {
          panel.padding(.top, 58).padding(.trailing, 30)
        })
    panelHost.frame = context.hosting.frame
    panelHost.autoresizingMask = [.width, .height]
    context.hosting.isHidden = true
    context.contentView.addSubview(panelHost)
    try await capture("site-controls.png", "Live HTTPS site control center on github.com.")
    panelHost.removeFromSuperview()
    context.hosting.isHidden = false

    let settings = BrowserSettingsView(
      profiles: host.settingsController!.profiles,
      searchEngines: BrowserSearchEngine.allCases.map {
        BrowserSettingsChoice(id: $0.rawValue, title: $0.displayName)
      },
      selectedProfileID: .constant(profile), sidebarInitiallyVisible: .constant(true),
      selectedSearchEngine: .constant(BrowserSearchEngine.google.rawValue),
      initialSection: .profiles
    )
    .environment(\.colorScheme, .light)
    let settingsHost = NSHostingView(rootView: settings)
    let settingsWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    settingsWindow.title = "Settings"
    settingsWindow.appearance = NSAppearance(named: .aqua)
    settingsWindow.contentView = settingsHost
    try await settle()
    try save(
      settingsWindow.contentView!.superview!, file: "profiles.png",
      description: "Settings > Profiles with the disposable Work and Personal profiles.")

    do {
      try await installStoreExtensions()
      // Store extensions may open their public welcome pages after installation completes.
      try await Task.sleep(for: .seconds(3))
      for tab in context.store.session.spaces.flatMap(\.tabs)
      where
        ["darkreader.org", "bitwarden.com"].contains(tab.url.host() ?? "")
      {
        context.store.closeTab(tab.id)
      }
      try await select(space: "Work")
      let manager = ExtensionManagerModel.shared(
        runtime: runtime, preferences: context.store.preferences,
        profileID: context.store.session.selectedSpace.profileID)
      extensionManager = manager
      manager.refresh()
      try await wait("two real pinned extension icons") {
        manager.pinnedExtensions.count == 2
          && manager.pinnedExtensions.allSatisfy { manager.icons[$0.id] != nil }
      }
      try await capture(
        "extensions.png", "Real Chrome Web Store extensions pinned in the Work profile.")
    } catch {
      skipped.append(["file": "extensions.png", "reason": error.localizedDescription])
    }
    do {
      try await captureMiniPlayer()
    } catch {
      skipped.append(["file": "mini-player.png", "reason": error.localizedDescription])
    }
    try writeManifest()
    finish(nil)
  }

  private func select(space name: String) async throws {
    let space = context.store.session.spaces.first { $0.name == name }!
    let tab = space.tabs[0]
    context.store.perform(.tab(space: space.id, tab: tab.id))
    _ = try await loaded(tab.id, expected: tab.url)
    try await settle()
  }

  private func loaded(_ tab: UUID, expected: URL) async throws -> [String: Any] {
    var last: [String: Any] = [:]
    defer {
      print("Page \(expected.absoluteString): \(last)")
      fflush(stdout)
    }
    try await wait("public page \(expected.absoluteString)", seconds: 45) {
      last =
        (try? await self.evaluate(
          tab,
          """
          ({url:location.href,title:document.title,ready:document.readyState,
            text:document.body?.innerText?.length || 0,fonts:document.fonts.status,
            images:[...document.images].filter(i=>i.getBoundingClientRect().top<innerHeight &&
              i.getBoundingClientRect().bottom>0).every(i=>i.complete),
            width:innerWidth,height:innerHeight,dpr:devicePixelRatio})
          """) as? [String: Any]) ?? [:]
      guard let address = last["url"] as? String, let url = URL(string: address) else {
        return false
      }
      return url.host() == expected.host() && url.path() == expected.path()
        && last["ready"] as? String == "complete" && last["fonts"] as? String == "loaded"
        && last["images"] as? Bool == true && (last["text"] as? Int ?? 0) > 100
        && self.context.engine.pages[tab]?.loading == false
    }
    try await settle()
    return last
  }

  private func capture(_ file: String, _ description: String) async throws {
    try await settle()
    let tab = context.store.session.selectedPage!.tab
    let document = try await loaded(tab.id, expected: tab.url)
    let data: Data? = await withCheckedContinuation { continuation in
      runtime.captureMarketingProbeTabID(tab.id.uuidString) { continuation.resume(returning: $0) }
    }
    guard let data, let image = NSImage(data: data),
      let bitmap = NSBitmapImageRep(data: data),
      let page = runtime.view(forTabID: tab.id.uuidString), let parent = page.superview
    else { throw Failure("Missing live Chromium viewport capture for \(file).") }
    guard bitmap.pixelsWide == Int(page.bounds.width * scale),
      bitmap.pixelsHigh == Int(page.bounds.height * scale)
    else {
      throw Failure(
        "Expected 2x viewport for \(file); PNG \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), native \(page.bounds), document \(document)."
      )
    }
    // AppKit cannot cache Chromium's remote layer. Substitute its unmodified live PNG
    // only during cacheDisplay; native chrome and Command-T remain above the real page.
    let replacement = NSImageView(frame: page.frame)
    replacement.image = image
    replacement.imageScaling = .scaleAxesIndependently
    parent.addSubview(replacement, positioned: .above, relativeTo: page)
    page.isHidden = true
    defer {
      page.isHidden = false
      replacement.removeFromSuperview()
    }
    let frame = context.window.contentView!.superview!
    try save(frame, file: file, description: description, document: document)
  }

  private func save(
    _ view: NSView, file: String, description: String, document: [String: Any]? = nil
  ) throws {
    guard NSApp.windows.allSatisfy({ !$0.isVisible }), !NSApp.isActive else {
      throw Failure("Capture refused: verification app became visible or active.")
    }
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { throw Failure("Cannot allocate 2x native bitmap.") }
    bitmap.size = size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw Failure("Cannot encode \(file).")
    }
    try data.write(to: root.appending(path: file), options: .atomic)
    var entry: [String: Any] = [
      "file": file, "description": description,
      "windowSize": ["width": size.width, "height": size.height, "unit": "points"],
      "pixelSize": ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh],
      "scale": scale, "appearance": "light", "engineVersion": runtime.chromiumVersion,
    ]
    if let document { entry["document"] = document }
    images.append(entry)
    print("Captured \(file): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    fflush(stdout)
  }

  private func installStoreExtensions() async throws {
    for (id, slug) in [
      ("eimadpbcbfnmbkopoojfekhnkhdbieeh", "dark-reader"),
      ("nngceckbapebfimnlniiiahkandclblb", "bitwarden-password-manager"),
    ] {
      let url = URL(string: "https://chromewebstore.google.com/detail/\(slug)/\(id)")!
      context.store.perform(.open(url))
      let tab = context.store.session.selectedPage!.tab.id
      defer { context.store.closeTab(tab) }
      try await wait("Chrome Web Store Add to Chrome for \(slug)", seconds: 25) {
        (try? await self.evaluate(
          tab,
          """
          [...document.querySelectorAll('button,[role="button"]')].some(b=>
            (b.innerText||b.getAttribute('aria-label')||'').trim().toLowerCase()==='add to chrome'
            && !b.disabled && b.getAttribute('aria-disabled')!=='true')
          """)) as? Bool == true
      }
      _ = try await evaluate(
        tab,
        """
        (()=>{const b=[...document.querySelectorAll('button,[role="button"]')].find(b=>
          (b.innerText||b.getAttribute('aria-label')||'').trim().toLowerCase()==='add to chrome');
          b?.click();return !!b;})()
        """, gesture: true)
      try await wait("store consent for \(slug)", seconds: 25) {
        self.context.store.installationRequests.contains { $0.browserExtension.id == id }
      }
      let consent = context.store.installationRequests.first { $0.browserExtension.id == id }!
      context.store.resolveInstallation(consent.id, accepted: true)
      let profile = context.store.session.selectedSpace.profileID
      try await wait("store installation for \(slug)", seconds: 35) {
        self.runtime.extensions(forProfileID: profile.uuidString).contains {
          $0["id"] as? String == id
        }
      }
      context.store.preferences.setExtension(id, pinned: true, for: profile)
      context.engine.refreshExtensions()
      let extensionInfo = runtime.extensions(forProfileID: profile.uuidString).first {
        $0["id"] as? String == id
      }!
      installed.append([
        "id": id, "name": extensionInfo["name"] ?? slug,
        "version": extensionInfo["version"] ?? "unknown", "sourceURL": url.absoluteString,
      ])
    }
  }

  private func captureMiniPlayer() async throws {
    try await select(space: "Personal")
    let music = context.store.session.selectedSpace.tabs.first {
      $0.url.host() == "music.youtube.com"
    }!
    context.store.setAutomaticPictureInPicture(
      false, for: music.url, profileID: context.store.session.selectedSpace.profileID)
    context.store.selectPage(music.id)
    guard
      context.engine.navigateCurrentPage(
        to: URL(string: "https://music.youtube.com/watch?v=jfKfPfyJRdk")!)
    else { throw Failure("Could not navigate YouTube Music.") }
    try await wait("signed-out muted YouTube Music playback", seconds: 30) {
      (try? await self.evaluate(
        music.id,
        """
        (()=>{const v=document.querySelector('video'); if(!v)return false;
          v.muted=true;v.play().catch(()=>{});return !v.paused && v.currentTime>0;})()
        """, gesture: true)) as? Bool == true
    }
    try await select(space: "Personal")
    try await wait("live sidebar mini player", seconds: 10) {
      self.context.store.miniPlayerItem?.tabID == music.id
    }
    try await capture(
      "mini-player.png", "Sidebar mini player with real YouTube Music playback, muted.")
  }

  private func evaluate(_ tab: UUID, _ script: String, gesture: Bool = false) async throws -> Any {
    let json: String? = await withCheckedContinuation { continuation in
      if gesture {
        runtime.evaluateProbeUserGesture(inTabID: tab.uuidString, script: script) {
          continuation.resume(returning: $0)
        }
      } else {
        runtime.evaluate(inTabID: tab.uuidString, script: script) {
          continuation.resume(returning: $0)
        }
      }
    }
    guard let json, let data = json.data(using: .utf8) else {
      throw Failure("Page evaluation unavailable.")
    }
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func wait(
    _ label: String, seconds: Double = 15, until ready: () async throws -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if try await ready() { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw Failure("Timed out waiting for \(label).")
  }

  private func settle() async throws {
    try await Task.sleep(for: .milliseconds(700))
    context?.hosting.layoutSubtreeIfNeeded()
  }

  private func writeManifest() throws {
    let manifest: [String: Any] = [
      "schema": 1, "capturedAt": ISO8601DateFormatter().string(from: Date()),
      "engineVersion": runtime.chromiumVersion, "images": images, "skipped": skipped,
      "extensions": installed,
      "captureMethod":
        "Hidden production host; live Chromium in-process viewport PNG inserted at its exact native frame, then whole-window AppKit bitmap at 2x. Site controls use the production panel with live HTTPS state in a hidden host. Settings uses the production Profiles view with the same workspace profiles.",
      "privacy":
        "Fresh marked temporary data directory, mock keychain, no sign-ins or existing profiles, prohibited app activation, no windows ordered onscreen, audio muted by the engine harness.",
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "manifest.json"), options: .atomic)
  }

  private func finish(_ error: Error?) {
    guard !finished else { return }
    finished = true
    passed = error == nil
    if let error { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
    runtime.quit()
  }
}
