// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import Foundation
import SwiftUI

@testable import ArcusisBrowser

enum WebsitePermissionProbeArguments {
  static func value(after flag: String, in arguments: [String]) -> String? {
    guard arguments.filter({ $0 == flag }).count == 1,
      let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
      !arguments[index + 1].hasPrefix("--")
    else {
      return nil
    }
    return arguments[index + 1]
  }
}

/// The run passes only when camera and microphone work and the four website prompts appear.
enum WebsitePermissionProbeVerdict {
  static let websitePrompts = ["geolocation", "notifications", "midi", "protocol"]

  static func passed(
    error: String?, mediaPrompted: Bool, mediaTracks: Bool, hidden: Bool,
    unexpectedSurfaces: [String], promptedNames: [String],
    rememberedKinds: [String] = [], openedProtocols: Set<String> = []
  ) -> Bool {
    let appeared = websitePrompts.allSatisfy { promptedNames.contains($0) }
    let remembered = ["geolocation", "notifications", "midi"].allSatisfy {
      rememberedKinds.contains($0)
    }
    return error == nil && mediaPrompted && mediaTracks && hidden && unexpectedSurfaces.isEmpty
      && appeared && remembered
      && Set(["web+shaarparity", "mailto"]).isSubset(of: openedProtocols)
  }
}

/// Hidden loopback check for the website permission sheet.
/// Camera and microphone must still arrive through the existing media event.
/// The three remembered grants are read back from Chromium site settings after Allow.
@MainActor
final class WebsitePermissionPromptProbe {
  private let runtime: ARCShaarRuntime
  private let host: NativeBrowserHost
  private let workspace: BrowserWorkspaceStore
  private let store: BrowserStore
  private let tabID: UUID
  private let output: URL
  private let dataRoot: URL
  private let fixture: URL
  private var finished = false
  private var passed = false
  private var mediaPrompted = false
  private var mediaTracks = false
  private var unexpectedSurfaces: [String] = []
  private var openedProtocols: Set<String> = []
  private var checks: [Check] = []
  private var screenshots: [String] = []
  private var previewWindow: NSWindow?

  private init(arguments: [String]) throws {
    func value(after flag: String) throws -> String {
      guard let value = WebsitePermissionProbeArguments.value(after: flag, in: arguments) else {
        throw Failure("Missing \(flag).")
      }
      return value
    }

    let framework = URL(filePath: try value(after: "--probe-framework"))
    guard let executable = Bundle.main.executableURL,
      ShaarFirstTabProbe.isBundledFramework(framework, for: executable)
    else {
      throw Failure(
        "The permission probe requires Shaar Verification.app and its bundled Chromium framework.")
    }
    output = URL(filePath: try value(after: "--probe-output"))
    dataRoot = URL(filePath: try value(after: "--probe-data-dir"), directoryHint: .isDirectory)
    guard
      (try? String(contentsOf: dataRoot.appending(path: ".arcusis-probe"), encoding: .utf8))
        == "arcusis-engine-probe-v1\n"
    else { throw Failure("Permission probe data directory is not a marked probe root.") }
    guard let page = URL(string: try value(after: "--probe-fixture-url")),
      page.scheme == "http", page.host == "127.0.0.1"
    else { throw Failure("Permission probe requires an owned loopback fixture.") }
    fixture = page
    let selected = try NativeBrowserHost.makeRuntime(frameworkURL: framework)
    guard let selected = selected as? ARCShaarRuntime else {
      throw Failure("The backend selector did not construct the Shaar runtime.")
    }
    runtime = selected
    workspace = try BrowserWorkspaceStore()
    guard let window = workspace.workspace.windows.first,
      let browser = workspace.stores[window.id]
    else { throw Failure("The fresh workspace has no browser window.") }
    store = browser
    let first = fixture.appending(path: "media")
    store.perform(.open(first))
    guard let id = store.session.selectedSpace.selectedTabID else {
      throw Failure("The fresh workspace did not create its first tab.")
    }
    tabID = id
    host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe)
  }

  static func run(arguments: [String]) -> Int32 {
    do {
      let probe = try WebsitePermissionPromptProbe(arguments: arguments)
      return probe.run()
    } catch {
      FileHandle.standardError.write(
        Data("Website permission probe: \(error.localizedDescription)\n".utf8))
      return 1
    }
  }

  private func run() -> Int32 {
    runtime.onReady = { [weak self] in
      guard let self else { return }
      do {
        try self.host.restore()
      } catch {
        self.finish(error: "Browser host restore failed: \(error)")
        return
      }
      Task { @MainActor [weak self] in
        await self?.exercise()
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 100) { [weak self] in
      self?.finish(error: "Timed out waiting for website permission checks.")
    }
    let result = runtime.run(withDataDirectory: dataRoot.appending(path: "Chromium"), testing: true)
    host.detach()
    return passed && result == 0 ? 0 : 1
  }

  private func exercise() async {
    do {
      guard host.contexts.values.contains(where: { $0.store === store }) else {
        throw Failure("The hidden browser did not restore a window.")
      }
      guard await waitForLiveTab() else {
        throw Failure("The permission fixture tab did not become live.")
      }
      for page in FixturePage.checks {
        checks.append(await run(page))
      }
      await verifyRegisteredHandlerLinks()
      finish(error: nil)
    } catch {
      finish(error: error.localizedDescription)
    }
  }

  private func verifyRegisteredHandlerLinks() async {
    for (scheme, registrationPath, target) in [
      ("web+shaarparity", "protocol", "web+shaarparity:hello"),
      ("mailto", "mailto", "mailto:probe@example.invalid"),
    ] {
      let source = fixture.appending(path: registrationPath)
      guard engine?.navigateCurrentPage(to: source) == true,
        await waitForPage(source, title: registrationPath)
      else { continue }
      _ = await evaluate("location.assign('\(target)'); true")
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        if let external = store.externalAppRequests.first {
          store.resolveExternalApp(external.id, accepted: false)
        }
        guard let url = store.session.selectedPage?.tab.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
          await pause(100)
          continue
        }
        if components.path == "/handled",
          components.queryItems?.contains(where: {
            $0.name == "u" && ($0.value ?? "").contains(target)
          }) == true
        {
          openedProtocols.insert(scheme)
          break
        }
        await pause(100)
      }
    }
  }

  private func run(_ page: FixturePage) async -> Check {
    var check = Check(name: page.name, kind: page.kind)
    let url = fixture.appending(path: page.path)
    if page.path != "media" {
      guard engine?.navigateCurrentPage(to: url) == true else {
        check.outcome = "navigation rejected"
        return check
      }
    }
    guard await waitForPage(url, title: page.name) else {
      check.outcome = "page did not load"
      return check
    }
    check.clicked = await click()
    if !check.clicked {
      await pause(300)
      check.clicked = await click()
    }
    let deadline = Date().addingTimeInterval(page.wait)
    while Date() < deadline {
      check.surfaces.append(contentsOf: hideUnexpectedSurfaces())
      if let request = store.websitePermissionRequests.first(where: { $0.tabID == tabID }) {
        check.kinds = request.kinds.map(\.rawValue)
        if !check.captured {
          let name = screenshotName(for: page)
          if (try? await capture(request, name: name)) != nil {
            check.captured = true
            screenshots.append(name)
          }
        }
        store.resolveWebsitePermission(request.id, accepted: page.allow)
        if page.verifyRemembered {
          check.remembered = await rememberedPermission(page.name, url: url)
        }
      }
      if let external = store.externalAppRequests.first {
        check.externalScheme = external.scheme
        store.resolveExternalApp(external.id, accepted: false)
      }
      if let result = await evaluate("window.parityResult"), result["outcome"] != nil {
        check.result = result
        if page.kind != "protocolHandler" || check.captured { break }
      }
      await pause(100)
    }
    if page.name == "media" {
      mediaPrompted = check.kinds.contains("camera") && check.kinds.contains("microphone")
      mediaTracks = mediaTracksReady(check.result)
    }
    return check
  }

  private func rememberedPermission(_ name: String, url: URL) async -> Bool {
    guard let engine else { return false }
    let permission: SitePermission
    switch name {
    case "geolocation": permission = .location
    case "notifications": permission = .notifications
    case "midi": permission = .midi
    default: return false
    }
    let model = SiteControlsModel(
      target: SiteControlTarget(
        tabID: tabID, profileID: store.session.selectedSpace.profileID, url: url),
      backend: engine)
    for _ in 0..<10 {
      await model.load()
      if model.permissionValues[permission] == .allow { return true }
      await pause(100)
    }
    return false
  }

  private func waitForLiveTab() async -> Bool {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if runtime.view(forTabID: tabID.uuidString) != nil,
        runtime.windowID(forTabID: tabID.uuidString) != nil,
        engine?.liveTabs.contains(tabID) == true
      {
        return true
      }
      await pause(100)
    }
    return false
  }

  private func waitForPage(_ url: URL, title: String) async -> Bool {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      let selected = store.session.selectedPage?.tab.id == tabID
      let sessionMatches = ShaarFirstTabProbe.matchesRequestedURL(
        store.session.selectedPage?.tab.url, requested: url)
      if selected && sessionMatches,
        let value = await evaluate("({title:document.title,path:location.pathname})"),
        value["title"] as? String == title,
        value["path"] as? String == "/\(title)"
      {
        return true
      }
      await pause(100)
    }
    return false
  }

  private func click() async -> Bool {
    await withCheckedContinuation { continuation in
      let gate = Once()
      runtime.submitTrustedProbeClick(inTabID: tabID.uuidString, elementID: "plain") {
        ok in
        guard gate.claim() else { return }
        continuation.resume(returning: ok)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard gate.claim() else { return }
        continuation.resume(returning: false)
      }
    }
  }

  private func evaluate(_ script: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      let gate = Once()
      runtime.evaluate(inTabID: tabID.uuidString, script: script) { json in
        guard gate.claim() else { return }
        continuation.resume(returning: json)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        guard gate.claim() else { return }
        continuation.resume(returning: nil)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func capture(_ request: WebsitePermissionRequest, name: String) async throws {
    let size = NSSize(width: 496, height: 440)
    let host = NSHostingView(
      rootView: WebsitePermissionConsent(store: store, request: request)
        .frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    previewWindow = window
    if window.isVisible {
      window.orderOut(nil)
      throw Failure("The consent preview became visible.")
    }
    await pause(100)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw Failure("Could not render the permission sheet.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
      throw Failure("Could not encode the permission sheet.")
    }
    try png.write(to: output.deletingLastPathComponent().appending(path: name), options: .atomic)
    window.orderOut(nil)
    previewWindow = nil
  }

  private func hideUnexpectedSurfaces() -> [String] {
    let names = unexpectedWindowNames()
    unexpectedSurfaces.append(contentsOf: names)
    return names
  }

  private func checkSurfaces() {
    unexpectedSurfaces.append(contentsOf: unexpectedWindowNames())
  }

  private func unexpectedWindowNames() -> [String] {
    let owned = host.contexts.values.map(\.window)
    var names: [String] = []
    for window in NSApp.windows where window.isVisible {
      if owned.contains(where: { $0 === window }) { continue }
      if window === previewWindow { continue }
      names.append(String(describing: type(of: window)))
      window.orderOut(nil)
    }
    return names
  }

  private func windowsHidden() -> Bool {
    previewWindow?.orderOut(nil)
    previewWindow = nil
    return NSApp.windows.allSatisfy { !$0.isVisible }
  }

  private func screenshotName(for page: FixturePage) -> String {
    if page.name == "media" { return "before-camera-microphone-consent.png" }
    if page.name == "protocol" { return "after-protocol-handler-consent.png" }
    return "\(page.name)-consent.png"
  }

  private func mediaTracksReady(_ result: [String: Any]) -> Bool {
    guard result["outcome"] as? String == "resolved" else { return false }
    let audio = (result["audio"] as? NSNumber)?.intValue ?? 0
    let video = (result["video"] as? NSNumber)?.intValue ?? 0
    return audio >= 1 && video >= 1
  }

  private var engine: BrowserEngine? {
    host.contexts.values.first { $0.store === store }?.engine
  }

  private func pause(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    let hidden = windowsHidden()
    let prompts = checks.filter(\.prompted).map(\.name)
    let websitePromptsAppeared = WebsitePermissionProbeVerdict.websitePrompts.allSatisfy {
      prompts.contains($0)
    }
    passed = WebsitePermissionProbeVerdict.passed(
      error: error, mediaPrompted: mediaPrompted, mediaTracks: mediaTracks, hidden: hidden,
      unexpectedSurfaces: unexpectedSurfaces, promptedNames: prompts,
      rememberedKinds: checks.filter(\.remembered).map(\.name),
      openedProtocols: openedProtocols)
    let report: [String: Any] = [
      "schemaVersion": 1,
      "probeMode": "website-permission-prompt",
      "passed": passed,
      "websitePromptsAppeared": websitePromptsAppeared,
      "mediaPrompted": mediaPrompted,
      "mediaTracks": mediaTracks,
      "allWindowsHidden": hidden,
      "unexpectedSurfaces": unexpectedSurfaces,
      "prompts": prompts,
      "openedProtocols": openedProtocols.sorted(),
      "rememberedPermissions": checks.filter(\.remembered).map(\.name),
      "checks": checks.map(\.json),
      "screenshots": screenshots,
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
      FileHandle.standardError.write(
        Data("Website permission report failed: \(error)\n".utf8))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      for context in self.host.contexts.values {
        _ = self.runtime.closeWindowID(context.nativeID)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.runtime.quit()
      }
    }
  }

  private struct FixturePage {
    let name: String
    let path: String
    let kind: String?
    let allow: Bool
    let wait: TimeInterval
    var verifyRemembered = false

    static let checks = [
      FixturePage(name: "media", path: "media", kind: nil, allow: true, wait: 8),
      FixturePage(
        name: "geolocation", path: "geolocation", kind: "location", allow: true, wait: 7,
        verifyRemembered: true),
      FixturePage(
        name: "notifications", path: "notifications", kind: "notifications", allow: true, wait: 6,
        verifyRemembered: true),
      FixturePage(
        name: "midi", path: "midi", kind: "midi", allow: true, wait: 6,
        verifyRemembered: true),
      FixturePage(
        name: "protocol", path: "protocol", kind: "protocolHandler", allow: true, wait: 4),
      FixturePage(
        name: "mailto", path: "mailto", kind: "protocolHandler", allow: true, wait: 4),
    ]
  }

  private struct Check {
    var name: String
    var kind: String?
    var clicked = false
    var kinds: [String] = []
    var outcome = ""
    var handledURL = ""
    var externalScheme = ""
    var surfaces: [String] = []
    var captured = false
    var remembered = false
    var result: [String: Any] = [:]

    var prompted: Bool {
      if name == "media" { return kinds.contains("camera") && kinds.contains("microphone") }
      if name == "protocol" { return kinds.contains("protocolHandler") }
      guard let kind else { return false }
      return kinds.contains(kind)
    }

    var json: [String: Any] {
      [
        "name": name,
        "kind": kind ?? "",
        "clicked": clicked,
        "kinds": kinds,
        "prompted": prompted,
        "remembered": remembered,
        "outcome": result["outcome"] as? String ?? outcome,
        "handledURL": handledURL,
        "externalScheme": externalScheme,
        "surfaces": surfaces,
      ]
    }
  }

  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if claimed { return false }
      claimed = true
      return true
    }
  }

  private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
