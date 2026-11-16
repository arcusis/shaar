// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import SwiftUI

@testable import ArcusisBrowser

/// Real public pages, disposable profiles, and the production hidden-window host.
/// Chromium's remote surface is captured through the existing in-process probe API and
/// inserted at its exact native viewport for bitmap rendering, including native overlays.
@MainActor
final class MarketingScreenshots {
  private let root: URL
  private let runtime: ARCChromiumRuntime
  private let rtlOnly: Bool
  private let httpsURL: URL?
  private var host: NativeBrowserHost?
  private var context: NativeBrowserContext!
  private var finished = false
  private var passed = false
  private var images: [[String: Any]] = []
  private var skipped: [[String: String]] = []
  private let size = NSSize(width: 1440, height: 960)
  private let offscreenOrigin = NSPoint(x: -10_000, y: -10_000)
  private let scale: CGFloat = 2

  private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  private init(root: URL, rtlOnly: Bool, httpsURL: URL?) throws {
    self.root = root
    self.rtlOnly = rtlOnly
    self.httpsURL = httpsURL
    guard let frameworks = Bundle.main.privateFrameworksURL else {
      throw Failure("Run the bundled verification executable.")
    }
    runtime = try ARCShaarRuntime(
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
      let rtlOnly = arguments.contains("--marketing-rtl")
      if rtlOnly { BrowserLanguage.applyToCurrentProcess() }
      let httpsURL = arguments.firstIndex(of: "--marketing-https-url")
        .flatMap { arguments.indices.contains($0 + 1) ? URL(string: arguments[$0 + 1]) : nil }
      let probe = try MarketingScreenshots(root: root, rtlOnly: rtlOnly, httpsURL: httpsURL)
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

  static func seed() throws -> BrowserSession {
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
          tab("https://arcusis.com/", "Arcusis", pinned: true),
          tab("https://github.com/arcusis/shaar", "Shaar"),
        ]),
      BrowserSpace(
        profileID: profiles[0].id, name: "Hasbara", symbol: "globe", tint: .ocean,
        tabs: [tab("https://hasbara.co.il/", "Hasbara", pinned: true)]),
      BrowserSpace(
        profileID: profiles[0].id, name: "Freight", symbol: "shippingbox", tint: .rose,
        customRGB: SpaceRGBColor(hex: "#DCA34B"),
        tabs: [tab("https://freightfte.com/", "Freight FTE", pinned: true)]),
    ]
    return try BrowserSession(profiles: profiles, spaces: spaces, selectedSpaceID: spaces[0].id)
  }

  private func captureAll() async throws {
    NSApp.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .aqua)
    let workspace = try BrowserWorkspaceStore(initialSession: Self.seed())
    let host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe,
      screens: { [NSRect(x: 0, y: 0, width: 1920, height: 1200)] })
    self.host = host
    try host.restore()
    guard let context = host.contexts.values.first else { throw Failure("Hidden host missing.") }
    self.context = context
    context.window.appearance = NSAppearance(named: .aqua)
    context.window.setFrame(NSRect(origin: offscreenOrigin, size: size), display: false)
    guard !NSScreen.screens.contains(where: { $0.frame.intersects(context.window.frame) }) else {
      throw Failure("Hidden host was placed on a display.")
    }
    try await settle()

    if rtlOnly {
      guard BrowserLanguage.currentLaunchLanguage == .hebrew else {
        throw Failure("RTL capture did not launch in Hebrew.")
      }
      try await select(space: "Work")
      try await capture("hebrew-window.png", "Hebrew right-to-left browser window on arcusis.com.")
      try writeManifest()
      finish(nil)
      return
    }
    if let httpsURL {
      context.store.perform(.open(httpsURL))
      guard let tab = context.store.session.selectedPage?.tab else {
        throw Failure("HTTPS warning tab missing.")
      }
      try await wait("HTTPS-first warning", seconds: 25) {
        guard let page = try? await self.evaluate(
          tab.id, "({text:document.body?.innerText||'',url:location.href})") as? [String: String],
          let text = page["text"], let url = page["url"]
        else { return false }
        return url == "chrome-error://chromewebdata/" && !text.contains("plain-http-loaded")
          && (text.contains("HTTPS") || text.localizedCaseInsensitiveContains("not secure"))
      }
      try await capture(
        "https-first-warning.png", "Live HTTPS-first warning for a plain HTTP site.",
        warningState: true)
      try writeManifest()
      finish(nil)
      return
    }

    // Visit every seeded page: titles, favicons and history come from the real engine.
    for space in context.store.session.spaces {
      for tab in space.tabs {
        print("Loading \(tab.url.absoluteString)")
        fflush(stdout)
        context.store.perform(.tab(space: space.id, tab: tab.id))
        _ = try await loaded(tab.id, expected: tab.url)
      }
    }
    // Capture page-only demo assets before installing extensions. Resize the hidden
    // native host until Chromium reports exactly 1440x900 CSS pixels; never crop chrome.
    for (spaceName, filename) in [
      ("Work", "page-arcusis.png"), ("Hasbara", "page-hasbara.png"),
      ("Freight", "page-freightfte.png"),
    ] {
      try await select(space: spaceName)
      try await capturePage(filename)
    }
    let work = context.store.session.spaces.first { $0.name == "Work" }!
    let github = work.tabs.first { $0.url.host() == "github.com" }!
    context.store.perform(.tab(space: work.id, tab: github.id))
    try await capturePage("page-github.png")
    context.window.setFrame(NSRect(origin: offscreenOrigin, size: size), display: false)
    try await select(space: "Work")
    try await capture("hero.png", "Green Work Space with the public Arcusis website.")
    try await capture(
      "extensions.png",
      "Extensions toolbar entry point on arcusis.com in the Work profile, before installation.")
    try await captureStopLoading()
    try await select(space: "Hasbara")
    try await capture(
      "spaces.png", "Blue Hasbara Space with hasbara.co.il and the sidebar visible.")
    try await select(space: "Work")
    let profile = context.store.session.selectedSpace.profileID
    context.store.showCommand()
    context.store.commandQuery = "freight"
    let results = context.store.commandSections.flatMap(\.results)
    guard results.contains(where: { if case .tab = $0.action { true } else { false } }),
      results.contains(where: { $0.isOpen })
    else { throw Failure("Launcher must include a real Freight tab and Open results.") }
    try await capture(
      "command-t.png", "Command-T searching freight across real public tabs over arcusis.com.")
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
        runExtension: { _ in }, addExtensions: {}, showCertificate: {}, showDeveloperTools: {},
        close: {})
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
    try await capture("site-controls.png", "Live HTTPS site control center on https://arcusis.com.")
    panelHost.removeFromSuperview()
    context.hosting.isHidden = false

    let settings = BrowserSettingsView(
      profiles: host.settingsController!.profiles,
      searchEngines: BrowserSearchEngine.allCases.map {
        BrowserSettingsChoice(id: $0.rawValue, title: $0.displayName)
      },
      selectedProfileID: .constant(profile), sidebarInitiallyVisible: .constant(true),
      selectedSearchEngine: .constant(BrowserSearchEngine.google.rawValue),
      httpsOnlyModeEnabled: { _ in true },
      onSetHttpsOnlyMode: { _, _ in true },
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

    try await captureStoreConsent()
    try orderOutOwnedOffscreenWindows()
    try await select(space: "Work")
    try await capturePrivateWindow()
    try captureFeatureScenes()
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
              i.getBoundingClientRect().bottom>0).every(i=>i.complete && i.naturalWidth>0),
            width:innerWidth,height:innerHeight,dpr:devicePixelRatio,
            dark:matchMedia('(prefers-color-scheme: dark)').matches})
          """) as? [String: Any]) ?? [:]
      guard let address = last["url"] as? String, let url = URL(string: address) else {
        return false
      }
      return url.host() == expected.host() && url.path() == expected.path()
        && last["ready"] as? String == "complete" && last["fonts"] as? String == "loaded"
        && (last["text"] as? Int ?? 0) > 100
        && self.context.engine.pages[tab]?.loading == false
    }
    try await dismissCookieBanner(tab)
    try await settle()
    return last
  }

  private func dismissCookieBanner(_ tab: UUID) async throws {
    let label = try await evaluate(
      tab,
      """
      (()=>{const visible=e=>{const r=e.getBoundingClientRect();const s=getComputedStyle(e);
        return r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight&&r.right>0&&
          r.left<innerWidth&&s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0'};
        const reject=[...document.querySelectorAll('button,[role="button"]')].find(e=>
          visible(e)&&!e.disabled&&/^(reject all|reject non-essential|decline all)$/i.test(
            (e.innerText||e.getAttribute('aria-label')||'').trim()));
        if(reject){const label=(reject.innerText||reject.getAttribute('aria-label')||'').trim();
          reject.click();return label;}
        const containers=[...document.querySelectorAll(
          '[role="dialog"],[id*="cookie" i],[class*="cookie" i],[id*="consent" i],[class*="consent" i]')];
        for(const c of containers.filter(visible)){
          const b=[...c.querySelectorAll('button,[role="button"]')].find(e=>visible(e)&&!e.disabled&&
            /^(reject( all| non-essential)?|decline( all)?|deny( all)?|close|dismiss|סגור|דחה הכל)$/i.test(
              (e.innerText||e.getAttribute('aria-label')||'').trim()));
          if(b){const label=(b.innerText||b.getAttribute('aria-label')||'').trim();
            b.click();return label;}}
        return null;})()
      """)
    if let label = label as? String {
      print("Dismissed visible cookie control: \(label)")
      try await settle()
    }
  }

  private func capturePage(_ file: String) async throws {
    guard let tab = context.store.session.selectedPage?.tab else {
      throw Failure("Missing selected public page.")
    }
    for _ in 0..<3 {
      try await settle()
      guard let page = runtime.view(forTabID: tab.id.uuidString) else {
        throw Failure("Missing Chromium viewport.")
      }
      let delta = NSSize(width: 1440 - page.bounds.width, height: 900 - page.bounds.height)
      if delta == .zero { break }
      var frame = context.window.frame
      frame.size.width += delta.width
      frame.size.height += delta.height
      context.window.setFrame(frame, display: false)
    }
    try await setCaptureScale(tab.id, width: 1440, height: 900)
    let document = try await loaded(tab.id, expected: tab.url)
    guard document["width"] as? Int == 1440, document["height"] as? Int == 900,
      document["dpr"] as? Int == 2, document["dark"] as? Bool == false,
      NSApp.windows.allSatisfy({ !$0.isVisible }), !NSApp.isActive
    else {
      throw Failure(
        "Page capture requires a hidden, light 1440x900 CSS viewport at 2x: \(document).")
    }
    let data = try await captureRetina(tab.id)
    guard let data, let bitmap = NSBitmapImageRep(data: data),
      bitmap.pixelsWide == 2880, bitmap.pixelsHigh == 1800
    else { throw Failure("Invalid page-only 2x PNG for \(file): \(data?.count ?? 0) bytes.") }
    try data.write(to: root.appending(path: file), options: .atomic)
    images.append([
      "file": file, "description": "Public page viewport only; no Shaar chrome.",
      "viewportSize": ["width": 1440, "height": 900, "unit": "CSS pixels"],
      "pixelSize": ["width": 2880, "height": 1800], "scale": scale,
      "appearance": "light", "engineVersion": runtime.chromiumVersion, "document": document,
    ])
    print("Captured \(file): 2880x1800 (1440x900 CSS)")
    fflush(stdout)
  }

  private func capture(
    _ file: String, _ description: String, loadingState: Bool = false,
    warningState: Bool = false
  ) async throws {
    try await settle()
    let tab = context.store.session.selectedPage!.tab
    guard let page = runtime.view(forTabID: tab.id.uuidString) else {
      throw Failure("Missing Chromium viewport for \(file).")
    }
    try await setCaptureScale(
      tab.id, width: Int(page.bounds.width), height: Int(page.bounds.height))
    let document = (loadingState || warningState) ? nil : try await loaded(tab.id, expected: tab.url)
    let data = try await captureRetina(tab.id)
    guard let data, let image = NSImage(data: data),
      let bitmap = NSBitmapImageRep(data: data),
      let parent = page.superview
    else { throw Failure("Missing live Chromium viewport capture for \(file).") }
    guard bitmap.pixelsWide == Int(page.bounds.width * scale),
      bitmap.pixelsHigh == Int(page.bounds.height * scale)
    else {
      throw Failure(
        "Expected 2x viewport for \(file); PNG \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), native \(page.bounds), document \(String(describing: document))."
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
    try save(
      frame, file: file, description: description, document: document,
      captureMethod: warningState
        ? "live HTTPS-first interstitial in the production hidden host at 2x"
        : loadingState
          ? "production hidden host with a simulated in-progress navigation callback; live page at 2x"
          : "hidden production host with live page and native chrome at 2x")
  }

  private func captureStopLoading() async throws {
    guard let tab = context.store.session.selectedPage?.tab else {
      throw Failure("Stop Loading capture needs a selected tab.")
    }
    runtime.onTabChanged?(
      tab.id.uuidString, tab.url.absoluteString, tab.title, true, false, false)
    guard context.engine.pages[tab.id]?.loading == true else {
      throw Failure("Loading callback did not reach the browser chrome.")
    }
    defer {
      runtime.onTabChanged?(
        tab.id.uuidString, tab.url.absoluteString, tab.title, false, false, false)
    }
    try await capture("stop-loading.png", "Stop Loading control during page navigation.",
                      loadingState: true)
  }

  private func setCaptureScale(_ tab: UUID, width: Int, height: Int) async throws {
    let tabID = tab.uuidString
    guard let profile = context.store.session.profileID(forTabID: tab),
      runtime.beginDeveloperSession(
        forTabID: tabID, profileID: profile.uuidString, windowID: context.engine.windowID)
    else { throw Failure("Could not open the hidden 2x capture session.") }
    let result: Error? = await withCheckedContinuation { continuation in
      runtime.developerCall(
        "Emulation.setDeviceMetricsOverride",
        params: ["width": width, "height": height, "deviceScaleFactor": 2, "mobile": false],
        tabID: tabID, profileID: profile.uuidString, windowID: context.engine.windowID
      ) { _, error in continuation.resume(returning: error) }
    }
    if let result {
      throw Failure("Could not set 2x capture metrics: \(result.localizedDescription)")
    }
  }

  private func captureRetina(_ tab: UUID) async throws -> Data? {
    // The probe lease forces a hidden renderer frame. CDP then captures the same
    // page at its temporary 2x metrics, since the host screen itself may be 1x.
    let warmed: Data? = await withCheckedContinuation { continuation in
      runtime.captureProbeTabID(tab.uuidString) { continuation.resume(returning: $0) }
    }
    guard warmed != nil, let profile = context.store.session.profileID(forTabID: tab) else {
      throw Failure("Hidden Chromium viewport did not paint.")
    }
    let response: (String?, String?) = await withCheckedContinuation { continuation in
      runtime.developerCall(
        "Page.captureScreenshot",
        params: ["format": "png", "captureBeyondViewport": false],
        tabID: tab.uuidString, profileID: profile.uuidString, windowID: context.engine.windowID
      ) { result, error in
        continuation.resume(returning: (result?["data"] as? String, error?.localizedDescription))
      }
    }
    if let error = response.1 {
      throw Failure("2x page capture failed: \(error)")
    }
    guard let encoded = response.0,
      let data = Data(base64Encoded: encoded)
    else { throw Failure("2x page capture returned no PNG.") }
    return data
  }

  private func save(
    _ view: NSView, file: String, description: String, document: [String: Any]? = nil,
    appearance: String = "light", captureMethod: String = "hidden production host"
  ) throws {
    guard NSApp.windows.allSatisfy({ !$0.isVisible }), !NSApp.isActive else {
      let visible = NSApp.windows.filter(\.isVisible).map {
        "\($0.title) \($0.frame)"
      }
      throw Failure("Capture refused: active=\(NSApp.isActive), visible=\(visible).")
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
      "scale": scale, "appearance": appearance, "engineVersion": runtime.chromiumVersion,
      "captureMethod": captureMethod,
    ]
    if let document { entry["document"] = document }
    images.append(entry)
    print("Captured \(file): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    fflush(stdout)
  }

  private func orderOutOwnedOffscreenWindows() throws {
    for window in NSApp.windows where window.isVisible {
      guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
        throw Failure("A verification window reached a display: \(window.title).")
      }
      window.orderOut(nil)
    }
    guard !NSApp.isActive else { throw Failure("Verification app became active.") }
  }

  /// Render production SwiftUI surfaces in an unordered window at the same Retina
  /// scale as the live host. These are component scenes, identified per image.
  private func captureScene<V: View>(
    _ view: V, file: String, description: String, size: NSSize,
    appearance: NSAppearance.Name = .aqua
  ) throws {
    let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    defer { window.close() }
    let hosted =
      view
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)
      .transaction { $0.disablesAnimations = true }
    let hosting = NSHostingView(rootView: hosted)
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    try save(
      hosting, file: file, description: description,
      appearance: scheme == .dark ? "dark" : "light",
      captureMethod: "production SwiftUI view in an unordered 2x AppKit host; no engine event")
  }

  private func capturePrivateWindow() async throws {
    guard let host else { throw Failure("Hidden host missing for private window.") }
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua),
                                  ("dark", NSAppearance.Name.darkAqua)] {
      let existing = Set(host.privateWindowOwners.map(\.windowID))
      NSApp.appearance = NSAppearance(named: appearance)
      host.perform(.newPrivateWindow)
      try await wait("hidden \(suffix) private start page", seconds: 20) {
        guard let owner = host.privateWindowOwners.first(where: {
          !existing.contains($0.windowID)
        }) else { return false }
        return !owner.window.isVisible
          && self.runtime.view(
            forPrivateTabID: owner.store.selectedTabID, windowID: owner.windowID,
            contextID: owner.contextID) != nil
      }
      guard let owner = host.privateWindowOwners.first(where: {
        !existing.contains($0.windowID)
      }) else { throw Failure("Private window owner missing.") }
      owner.window.setFrame(
        NSRect(origin: offscreenOrigin, size: NSSize(width: 1100, height: 720)),
        display: false)
      owner.window.appearance = NSAppearance(named: appearance)
      owner.hosting.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(700))
      try save(
        owner.window.contentView!.superview!, file: "private-window-\(suffix).png",
        description: "Private start page in a real hidden private window.",
        appearance: suffix,
        captureMethod: "production hidden private host rendered offscreen at 2x")
    }
    NSApp.appearance = NSAppearance(named: .aqua)
    try orderOutOwnedOffscreenWindows()
  }

  private func captureFeatureScenes() throws {
    let store = context.store
    guard let tab = store.session.selectedSpace.selectedTab else {
      throw Failure("Feature scenes require the selected public tab.")
    }
    let profile = store.session.selectedSpace.profileID
    let light = NSAppearance.Name.aqua
    let dark = NSAppearance.Name.darkAqua
    let download = BrowserDownload(
      id: UUID().uuidString, profileID: profile, filename: "Shaar-0.2.0.dmg",
      path: "/tmp/Shaar-0.2.0.dmg", sourceURL: "https://example.test/Shaar-0.2.0.dmg",
      state: .downloading, paused: false, dangerous: false, offTheRecord: false,
      received: 45, total: 100, startTime: 1)
    guard let download else { throw Failure("Could not construct downloads scene.") }
    for (suffix, appearance) in [("light", light), ("dark", dark)] {
      try captureScene(
        RecentDownloadsPopover(
          items: [download], profileID: profile, selectedProfileID: { profile },
          dragURL: { $0.fileURL }, dismiss: {}, animatesReveal: false),
        file: "downloads-\(suffix).png",
        description: "Downloads drawer with an in-progress download.",
        size: NSSize(width: 320, height: 260), appearance: appearance)
    }

    let dialog = JavaScriptDialogRequest(payload: [
      "id": "marketing-alert", "profileID": profile.uuidString,
      "tabID": tab.id.uuidString, "pageURL": tab.url.absoluteString,
      "origin": "https://arcusis.com", "dialogType": JavaScriptDialogKind.alert.rawValue,
      "message": "Welcome to Shaar 0.2.0", "defaultPrompt": "",
    ])
    guard let dialog else { throw Failure("Could not construct JavaScript dialog scene.") }
    try captureScene(
      JavaScriptDialogSheet(request: dialog, store: store), file: "javascript-dialog.png",
      description: "Native JavaScript alert sheet.", size: NSSize(width: 520, height: 440))
    let auth = HTTPAuthRequest(payload: [
      "id": "marketing-auth", "profileID": profile.uuidString,
      "tabID": tab.id.uuidString, "windowID": context.engine.windowID,
      "host": "arcusis.com", "realm": "Members",
    ])
    guard let auth else { throw Failure("Could not construct Basic auth scene.") }
    try captureScene(
      HTTPAuthSheet(store: store, request: auth), file: "basic-auth.png",
      description: "Native HTTP Basic authentication sheet.",
      size: NSSize(width: 520, height: 440))

    let permission = WebsitePermissionRequest(
      id: "marketing-permission", profileID: profile, tabID: tab.id,
      pageURL: tab.url, requestingOrigin: URL(string: "https://arcusis.com")!,
      kinds: [.camera, .microphone, .location])
    guard let permission else { throw Failure("Could not construct permission scene.") }
    try captureScene(
      WebsitePermissionConsent(store: store, request: permission),
      file: "permission-camera-mic-location.png",
      description: "Camera, microphone and location permission prompt.",
      size: NSSize(width: 500, height: 560))

    let external = ExternalAppRequest(
      id: "x1", profileID: profile, tabID: tab.id,
      pageURL: tab.url, scheme: "mailto", requestingOrigin: tab.url,
      applicationName: "Mail", windowID: context.engine.windowID)
    guard let external else { throw Failure("Could not construct protocol scene.") }
    try captureScene(
      ExternalAppConsent(store: store, request: external), file: "protocol-handler.png",
      description: "External protocol handler consent for Mail.",
      size: NSSize(width: 500, height: 540))

    for transport in [DeviceChooserTransport.bluetooth, .serial] {
      let chooser = DeviceChooserRequest(
        id: "marketing-\(transport.rawValue)", tabID: tab.id, profileID: profile,
        pageURL: tab.url, origin: tab.url, transport: transport,
        options: [], bluetoothUnavailable: transport == .bluetooth, canGrant: false)
      try captureScene(
        DeviceChooserConsent(store: store, request: chooser),
        file: "device-chooser-\(transport.rawValue).png",
        description: "\(transport.rawValue.capitalized) device chooser consent.",
        size: NSSize(width: 500, height: 420))
    }

    let media = MediaSessionState(
      playbackState: .playing, title: "Sample video", artist: "Shaar",
      actions: [.pause, .previousTrack, .nextTrack], volume: 0.35)
    let mini = MiniPlayerItem(tabID: tab.id, pageTitle: "Sample video", favicon: nil, state: media)
    for (suffix, appearance) in [("light", light), ("dark", dark)] {
      try captureScene(
        SidebarMediaPlayer(volumeIsVisible: true, item: mini, onSelect: {}, onCommand: { _ in }),
        file: "media-controls-\(suffix).png", description: "Sidebar media controls.",
        size: NSSize(width: BrowserChromeLayout.sidebarWidth, height: 100),
        appearance: appearance)
    }
    let pipSize = NSSize(width: 356, height: 200)
    let pip = PictureInPictureControlsView(frame: NSRect(origin: .zero, size: pipSize))
    pip.presentation = .init(isPlaying: true, isLive: false)
    pip.setControlsShown(true, animated: false)
    let video = NSView(frame: pip.frame)
    video.wantsLayer = true
    video.layer?.backgroundColor =
      NSColor(
        srgbRed: 0.14, green: 0.24, blue: 0.34, alpha: 1
      ).cgColor
    video.addSubview(pip)
    let pipWindow = NSWindow(
      contentRect: NSRect(origin: .zero, size: pipSize), styleMask: .borderless,
      backing: .buffered, defer: false)
    pipWindow.isReleasedWhenClosed = false
    pipWindow.contentView = video
    pip.layoutSubtreeIfNeeded()
    pipWindow.displayIfNeeded()
    defer { pipWindow.close() }
    try save(
      video, file: "picture-in-picture.png",
      description: "Picture-in-picture controls over a sample video backdrop.",
      captureMethod: "production AppKit PiP controls rendered offscreen at 2x")

    let settings = BrowserSettingsView(
      profiles: host!.settingsController!.profiles,
      searchEngines: BrowserSearchEngine.allCases.map {
        BrowserSettingsChoice(id: $0.rawValue, title: $0.displayName)
      },
      selectedProfileID: .constant(profile), sidebarInitiallyVisible: .constant(true),
      selectedSearchEngine: .constant(BrowserSearchEngine.google.rawValue),
      httpsOnlyModeEnabled: { _ in true }, onSetHttpsOnlyMode: { _, _ in true },
      initialSection: .general)
    try captureScene(
      settings, file: "sleeping-tabs-settings.png",
      description: "Settings showing sleeping tabs controls.",
      size: NSSize(width: 900, height: 732))
  }

  private func captureStoreConsent() async throws {
    for (id, slug) in [
      ("nngceckbapebfimnlniiiahkandclblb", "bitwarden-password-manager")
    ] {
      let url = URL(string: "https://chromewebstore.google.com/detail/\(slug)/\(id)")!
      context.store.perform(.open(url))
      let tab = context.store.session.selectedPage!.tab.id
      defer { context.store.closeTab(tab) }
      print("Capturing Chrome Web Store consent: \(slug)")
      fflush(stdout)
      try await wait("Chrome Web Store Add to Chrome for \(slug)", seconds: 60) {
        if self.context.store.session.selectedPage?.tab.id != tab {
          let space = self.context.store.session.spaces.first { $0.tabs.contains { $0.id == tab } }!
          self.context.store.perform(.tab(space: space.id, tab: tab))
        }
        return
          (try? await self.evaluate(
            tab,
            """
            [...document.querySelectorAll('button,[role="button"]')].some(b=>
              (b.innerText||b.getAttribute('aria-label')||'').trim().toLowerCase()==='add to chrome'
              && !b.disabled && b.getAttribute('aria-disabled')!=='true')
            """)) as? Bool == true
      }
      var clicked = false
      for _ in 0..<3 {
        let space = context.store.session.spaces.first { $0.tabs.contains { $0.id == tab } }!
        context.store.perform(.tab(space: space.id, tab: tab))
        try await settle()
        let painted: Data? = await withCheckedContinuation { continuation in
          runtime.captureProbeTabID(tab.uuidString) { continuation.resume(returning: $0) }
        }
        guard painted != nil else { continue }
        clicked = await withCheckedContinuation { continuation in
          runtime.clickProbeElement(inTabID: tab.uuidString, elementID: "webstore-add-to-chrome") {
            continuation.resume(returning: $0)
          }
        }
        if clicked { break }
        try await Task.sleep(for: .seconds(1))
      }
      guard clicked else {
        let page = try? await evaluate(
          tab,
          "({url:location.href,button:[...document.querySelectorAll('button')].find(b=>b.innerText.trim().toLowerCase()==='add to chrome')?.outerHTML||null})"
        )
        throw Failure("Trusted Web Store click failed for \(slug): \(String(describing: page)).")
      }
      try await wait("store consent for \(slug)", seconds: 25) {
        self.context.store.installationRequests.contains { $0.browserExtension.id == id }
      }
      let consent = context.store.installationRequests.first { $0.browserExtension.id == id }!
      if id == "nngceckbapebfimnlniiiahkandclblb" {
        try captureScene(
          ExtensionConsent(store: context.store, request: consent),
          file: "web-store-bitwarden-consent.png",
          description:
            "Actual Bitwarden Chrome Web Store installation request in the hidden production host.",
          size: NSSize(width: 550, height: 650))
      }
      context.store.resolveInstallation(consent.id, accepted: false)
    }
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
      "schema": 2, "capturedAt": ISO8601DateFormatter().string(from: Date()),
      "engineVersion": runtime.chromiumVersion, "images": images, "skipped": skipped,
      "extensions": [],
      "captureMethod":
        "Hidden production host; live Chromium probe viewport PNG at temporary 2x device metrics inserted at its exact native frame, then whole-window AppKit bitmap at 2x. Site controls use the production panel with live HTTPS state in a hidden host. Settings uses the production Profiles view with the same workspace profiles. Page-only images use the engine viewport PNG at exactly 1440x900 CSS pixels, 2x, before extension installation. Standalone feature surfaces are production views rendered in unordered AppKit windows at 2x; each image identifies its method.",
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
