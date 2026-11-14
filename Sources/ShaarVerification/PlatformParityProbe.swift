// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CoreFoundation
import Foundation
import ObjectiveC

@testable import ArcusisBrowser

enum PlatformParityPreferenceEvidence {
  static func excerpt(_ root: [String: Any]) -> [String: String] {
    var values: [String: String] = [:]
    func store(_ key: String, _ value: Any?) {
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return
      }
      values[key] = number.boolValue ? "true" : "false"
    }
    let safe = root["safebrowsing"] as? [String: Any]
    store("safebrowsing.enabled", safe?["enabled"])
    store("safebrowsing.enhanced", safe?["enhanced"])
    store("https_only_mode_enabled", root["https_only_mode_enabled"])
    let autofill = root["autofill"] as? [String: Any]
    store("autofill.profile_enabled", autofill?["profile_enabled"])
    store("autofill.credit_card_enabled", autofill?["credit_card_enabled"])
    store("credentials_enable_service", root["credentials_enable_service"])
    if let profile = root["profile"] as? [String: Any],
      let mode = profile["cookie_controls_mode"] as? NSNumber,
      CFGetTypeID(mode) != CFBooleanGetTypeID()
    {
      values["profile.cookie_controls_mode"] = mode.stringValue
    }
    return values
  }
}

/// Hidden audit of web-platform prompts, pickers, and delegates.
/// Runs in the verification harness. Loopback fixtures only; windows stay off screen.
@MainActor enum PlatformParityProbe {
  static func run(
    frameworkURL: URL, outputURL: URL, httpBase: URL?, httpsBase: URL?,
    widevineOnly: Bool = false
  ) -> Int32 {
    guard let httpBase, httpBase.scheme == "http", httpBase.host == "127.0.0.1",
      httpBase.port.map({ (1...65_535).contains($0) }) == true,
      let httpsBase, httpsBase.scheme == "https", httpsBase.host == "127.0.0.1",
      httpsBase.port.map({ (1...65_535).contains($0) }) == true
    else { return 2 }
    let directory = outputURL.deletingLastPathComponent()
    do {
      let workspace = try BrowserWorkspaceStore(
        file: WorkspaceFile(
          url: directory.appending(path: "profile/workspace.json"),
          legacySessionURL: directory.appending(path: "profile/session.json")))
      let runtime = try ARCShaarRuntime(frameworkURL: frameworkURL)
      let host = NativeBrowserHost(
        events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
        presentation: .hiddenProbe)
      let run = PlatformParityRun(
        host: host, runtime: runtime, http: httpBase, https: httpsBase,
        dataRoot: directory.appending(path: "Chromium"), outputURL: outputURL,
        widevineOnly: widevineOnly)
      runtime.onReady = {
        NSApp.setActivationPolicy(.prohibited)
        Task { await run.execute() }
      }
      return withExtendedLifetime(host) {
        let code = runtime.run(
          withDataDirectory: directory.appending(path: "Chromium"), testing: true)
        host.detach()
        return code
      }
    } catch {
      write(["completed": false, "error": error.localizedDescription], to: outputURL)
      return 1
    }
  }
}

private struct ParityCheck {
  enum Base { case http, https, plainHost, localhost }
  let item: String
  let path: String
  let base: Base
  let click: Bool
  let seconds: Double
  let allowMedia: Bool
  let tolerateErrorPage: Bool
}

private struct ScriptEvaluation {
  var value: [String: Any]?
  var timedOut: Bool
}

private final class EvaluateOnce: @unchecked Sendable {
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

private struct ParitySnapshot {
  var result: [String: Any] = [:]
  var kinds: [String] = []
  var sheet = ""
  var surfaces: [String] = []
  var events: [String] = []
  var downloads: [String] = []
  var extensions: [String] = []
  var installedMV3 = false
  var mediaTitle = ""
  var pictureInPicture = false
  var security = ""
  var href = ""
  var pageText = ""
  var pageTitle = ""
  var committedURL = ""
  var popupURL = ""
  var cookiesBlocked = ""
  var opened = false
  var attemptedClick = false
  var clicked = false
  var surfaceBaseline = 0
  var scriptStalled = false
}

@MainActor private final class PlatformParityRun {
  let host: NativeBrowserHost
  let runtime: ARCShaarRuntime
  let http: URL
  let https: URL
  let dataRoot: URL
  let outputURL: URL
  let widevineOnly: Bool
  private var rows: [[String: Any]] = []
  private var userAgent = ""
  private var preferences: [String: String] = [:]
  private var loopbackPeer = ""
  private var completed = false

  init(
    host: NativeBrowserHost, runtime: ARCShaarRuntime, http: URL, https: URL, dataRoot: URL,
    outputURL: URL, widevineOnly: Bool
  ) {
    self.host = host
    self.runtime = runtime
    self.http = http
    self.https = https
    self.dataRoot = dataRoot
    self.outputURL = outputURL
    self.widevineOnly = widevineOnly
  }

  func execute() async {
    defer {
      if !widevineOnly { replaceSafeBrowsingRow() }
      SurfaceGuard.stopWatchdog()
      publish()
      host.events.quit()
    }
    SurfaceGuard.install()
    let missing = SurfaceGuard.installed.filter { $0.hasPrefix("missing") }
    guard missing.isEmpty else {
      rows.append(
        probeRow(
          "Setup",
          evidence:
            "Surface guard did not install before the window was restored. \(missing.joined(separator: ", "))"
        ))
      return
    }
    SurfaceGuard.startWatchdog()
    do { try host.restore() } catch {
      rows.append(probeRow("Setup", evidence: error.localizedDescription))
      return
    }
    guard context != nil else {
      rows.append(probeRow("Setup", evidence: "No hidden window."))
      return
    }
    let ready = await run(
      ParityCheck(
        item: "Ready", path: "/ready", base: .http, click: false, seconds: 8,
        allowMedia: false, tolerateErrorPage: false), loadTimeout: 25)
    guard text(ready.result["outcome"]) == "ready" else {
      rows.append(probeRow("Setup", evidence: "The fixture page did not load. \(describe(ready))"))
      return
    }
    for check in checks() {
      let snapshot = await run(check, loadTimeout: 12)
      if let agent = snapshot.result["userAgent"] as? String, userAgent.isEmpty {
        userAgent = agent
      }
      rows.append(contentsOf: verdicts(check, snapshot))
      publish()
    }
    if widevineOnly {
      completed = true
      return
    }
    let partition = await runPartition()
    rows.append(partition)
    replaceSafeBrowsingRow()
    publish()
    // Device choosers can block the main thread inside a system framework.
    // An in-progress row is on disk before each one starts, so a hang names the check
    // without inventing the cause.
    for check in deviceChecks() {
      rows.append(inProgressRow(check.item))
      publish()
      let snapshot = await run(check, loadTimeout: 12)
      rows.removeAll {
        $0["item"] as? String == check.item && $0["result"] as? String == "in progress"
      }
      rows.append(contentsOf: verdicts(check, snapshot))
      publish()
    }
    let measured = rows.contains { row in
      let item = row["item"] as? String ?? ""
      let result = row["result"] as? String ?? ""
      return item != "Setup" && item != "Safe Browsing state" && result != "in progress"
    }
    if measured {
      completed = true
    }
  }

  private func replaceSafeBrowsingRow() {
    preferences = readPreferences()
    rows.removeAll { $0["item"] as? String == "Safe Browsing state" }
    rows.append(safeBrowsingRow())
  }

  private func deviceChecks() -> [ParityCheck] {
    [
      item("Web USB chooser", "/usb"),
      item("Web HID chooser", "/hid"),
      item("Web Serial chooser", "/serial"),
      item("Web Bluetooth chooser", "/bluetooth"),
    ]
  }

  private var context: NativeBrowserContext? { host.contexts.values.first }

  private func checks() -> [ParityCheck] {
    let eme = ParityCheck(
      item: "EME/Widevine", path: "/eme", base: .http, click: false, seconds: 6,
      allowMedia: false, tolerateErrorPage: false)
    let playback = ParityCheck(
      item: "Widevine test stream", path: "/widevine-playback", base: .http,
      click: false, seconds: 35, allowMedia: false, tolerateErrorPage: false)
    if widevineOnly { return [eme, playback] }
    let media = ParityCheck(
      item: "Camera and microphone", path: "/media", base: .http, click: true, seconds: 8,
      allowMedia: true, tolerateErrorPage: false)
    return [
      media,
      item("Geolocation permission", "/geolocation", seconds: 6),
      item("Notifications permission", "/notifications"),
      item("Clipboard permission", "/clipboard"),
      item("MIDI permission", "/midi"),
      item("Storage access permission", "/storage-access", seconds: 6),
      ParityCheck(
        item: "WebAuthn/passkeys", path: "/webauthn", base: .localhost, click: true, seconds: 5,
        allowMedia: false, tolerateErrorPage: false),
      item("File System Access pickers", "/file-picker"),
      item("Web Share", "/share"),
      item("Screen sharing picker", "/screen", seconds: 6),
      item("Payment Request", "/payment"),
      item("Protocol handlers", "/protocol", seconds: 6),
      item("Autofill addresses", "/address", seconds: 6),
      item("Autofill cards", "/card", seconds: 6),
      item("Autofill passwords", "/password", seconds: 6),
      ParityCheck(
        item: "WebGPU", path: "/webgpu", base: .http, click: false, seconds: 6,
        allowMedia: false, tolerateErrorPage: false),
      ParityCheck(
        item: "WebGL", path: "/webgl", base: .http, click: false, seconds: 4,
        allowMedia: false, tolerateErrorPage: false),
      eme,
      item("Picture in Picture", "/pip", seconds: 6),
      item("Media Session", "/media-session", seconds: 6),
      item("Popups/window.open", "/popup"),
      item("Downloads", "/download", seconds: 8),
      item("Print", "/print", seconds: 4),
      ParityCheck(
        item: "PDF viewer", path: "/page.pdf", base: .http, click: false, seconds: 6,
        allowMedia: false, tolerateErrorPage: false),
      ParityCheck(
        item: "Extensions (MV3) basics", path: "/extensions-page", base: .http, click: false,
        seconds: 3, allowMedia: false, tolerateErrorPage: false),
      item("PWA install", "/pwa/", seconds: 8),
      ParityCheck(
        item: "trackertest.org loopback", path: "/loopback", base: .plainHost, click: false,
        seconds: 6, allowMedia: false, tolerateErrorPage: false),
      ParityCheck(
        item: "HTTPS-first", path: "/plain", base: .plainHost, click: false, seconds: 6,
        allowMedia: false, tolerateErrorPage: true),
      ParityCheck(
        item: "Certificate errors", path: "/bad-cert", base: .https, click: false, seconds: 6,
        allowMedia: false, tolerateErrorPage: true),
    ]
  }

  private func item(
    _ name: String, _ path: String, seconds: Double = 5
  ) -> ParityCheck {
    ParityCheck(
      item: name, path: path, base: .http, click: true, seconds: seconds,
      allowMedia: false, tolerateErrorPage: false)
  }

  private func run(_ check: ParityCheck, loadTimeout: Double) async -> ParitySnapshot {
    guard let context, let page = pageURL(check) else { return ParitySnapshot() }
    trimTabs(in: context)
    var snapshot = ParitySnapshot()
    snapshot.opened = await open(
      page, in: context, timeout: loadTimeout, tolerateErrorPage: check.tolerateErrorPage)
    snapshot.surfaceBaseline = SurfaceGuard.count
    guard snapshot.opened else {
      await observe(&snapshot, in: context, allowMedia: false)
      return snapshot
    }
    if check.path == "/storage-access" {
      _ = await waitForReady(in: context)
    }
    if check.click {
      snapshot.attemptedClick = true
      let clicked = await click(in: context)
      snapshot.clicked = clicked.landed
      if clicked.timedOut { snapshot.scriptStalled = true }
    }
    let deadline = Date().addingTimeInterval(check.seconds)
    while Date() < deadline && !snapshot.scriptStalled {
      await observe(&snapshot, in: context, allowMedia: check.allowMedia)
      if isDone(check.item, snapshot) || snapshot.scriptStalled { break }
      try? await Task.sleep(for: .milliseconds(150))
    }
    if !snapshot.scriptStalled {
      await observe(&snapshot, in: context, allowMedia: check.allowMedia)
    }
    if check.item == "Protocol handlers", text(snapshot.result["outcome"]) == "registered" {
      await followProtocol(&snapshot, in: context)
    }
    if check.item == "Extensions (MV3) basics" {
      snapshot.extensions = await extensionNames(in: context)
    }
    return snapshot
  }

  private func runPartition() async -> [String: Any] {
    guard let context else {
      return probeRow("Storage partitioning / third-party cookies", evidence: "No window.")
    }
    let writeURL = pageURL(path: "/partition-a", base: .http)
    let readURL = pageURL(path: "/partition-b", base: .plainHost)
    guard let writeURL, let readURL else {
      return probeRow("Storage partitioning / third-party cookies", evidence: "Bad partition URL.")
    }
    trimTabs(in: context)
    var write = ParitySnapshot()
    write.opened = await open(writeURL, in: context, timeout: 12, tolerateErrorPage: false)
    write = await settle(write, in: context, seconds: 6)
    trimTabs(in: context)
    var read = ParitySnapshot()
    read.opened = await open(readURL, in: context, timeout: 12, tolerateErrorPage: false)
    read = await settle(read, in: context, seconds: 6)
    return partitionRow(write: write, read: read)
  }

  private func settle(
    _ initial: ParitySnapshot, in context: NativeBrowserContext, seconds: Double
  ) async -> ParitySnapshot {
    var snapshot = initial
    let ticks = Int(seconds * 10)
    for _ in 0..<ticks {
      await observe(&snapshot, in: context, allowMedia: false)
      if !text(snapshot.result["mode"]).isEmpty || !text(snapshot.result["storageError"]).isEmpty {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return snapshot
  }

  private func open(
    _ url: URL, in context: NativeBrowserContext, timeout: Double, tolerateErrorPage: Bool
  ) async -> Bool {
    context.store.perform(.open(url))
    return await wait(timeout) {
      guard let current = self.selectedURL(in: context) else { return false }
      let loaded = self.selectedLoading(in: context) == false
      if self.samePage(current, url) && loaded { return true }
      let security = self.securityLevel(in: context) ?? ""
      return tolerateErrorPage && loaded && PlatformParityVerdicts.isCertificateError(security)
    }
  }

  private func observe(
    _ snapshot: inout ParitySnapshot, in context: NativeBrowserContext, allowMedia: Bool
  ) async {
    settleConsent(allowMedia: allowMedia, in: context, snapshot: &snapshot)
    snapshot.committedURL = selectedURL(in: context)?.absoluteString ?? snapshot.committedURL
    snapshot.security = securityLevel(in: context) ?? snapshot.security
    snapshot.cookiesBlocked = cookiePolicy(in: context)
    let profile = context.store.session.selectedSpace.profileID
    snapshot.downloads = context.engine.downloads.items(in: profile).map(\.filename)
    if let tab = selectedTabID(in: context), let session = context.store.media.sessions[tab] {
      if !session.title.isEmpty { snapshot.mediaTitle = session.title }
      if session.pictureInPicture != nil { snapshot.pictureInPicture = true }
    }
    if let tab = context.engine.pictureInPictureControls.tabID {
      snapshot.pictureInPicture = true
      runtime.exitPictureInPicture(inTabID: tab.uuidString)
    }
    let tabs = context.store.session.spaces.flatMap(\.tabs)
    if let landed = tabs.first(where: { $0.url.path == "/landed" }) {
      snapshot.popupURL = landed.url.absoluteString
    }
    let result = await evaluate(in: context, "window.parityResult")
    if result.timedOut { snapshot.scriptStalled = true }
    if let value = result.value, !value.isEmpty { snapshot.result = value }
    let page = await evaluate(
      in: context,
      "({href:location.href,title:document.title,text:(document.body&&document.body.innerText||'').slice(0,300)})"
    )
    if page.timedOut { snapshot.scriptStalled = true }
    if let value = page.value {
      snapshot.href = text(value["href"])
      snapshot.pageTitle = text(value["title"])
      snapshot.pageText = text(value["text"])
    }
    for name in SurfaceGuard.names(after: snapshot.surfaceBaseline) {
      recordSurface(name, on: &snapshot)
    }
  }

  private func settleConsent(
    allowMedia: Bool, in context: NativeBrowserContext, snapshot: inout ParitySnapshot
  ) {
    let browserWindows = browserWindowClassNames
    for window in NSApp.windows where window.isVisible {
      if !isBrowserOwnedWindow(window, browserWindows: browserWindows) {
        let name = "visible \(type(of: window))"
        if !snapshot.surfaces.contains(name) { snapshot.surfaces.append(name) }
      }
      window.orderOut(nil)
    }
    for _ in 0..<5 {
      if let request = context.store.websitePermissionRequests.first {
        for kind in request.kinds.map(\.rawValue) where !snapshot.kinds.contains(kind) {
          snapshot.kinds.append(kind)
        }
        let mediaOnly = request.kinds.allSatisfy { $0 == .camera || $0 == .microphone }
        context.store.resolveWebsitePermission(request.id, accepted: allowMedia && mediaOnly)
        continue
      }
      if case .desktopCapture(let request) = context.store.sheet {
        snapshot.sheet = "desktopCapture"
        context.store.resolveDesktopCapture(request.id, sourceID: nil)
        continue
      }
      if let request = context.store.externalAppRequests.first {
        snapshot.sheet = "externalApp:\(request.scheme)"
        context.store.resolveExternalApp(request.id, accepted: false)
        continue
      }
      if let request = context.store.installationRequests.first {
        snapshot.sheet = "extensionInstall"
        context.store.resolveInstallation(request.id, accepted: false)
        continue
      }
      break
    }
  }

  private func followProtocol(
    _ snapshot: inout ParitySnapshot, in context: NativeBrowserContext
  ) async {
    let navigation = await evaluate(in: context, "location.assign('web+shaarparity:hello')")
    if navigation.timedOut { snapshot.scriptStalled = true }
    for _ in 0..<30 {
      await observe(&snapshot, in: context, allowMedia: false)
      if snapshot.href.contains("/handled") || snapshot.committedURL.contains("/handled")
        || snapshot.sheet.hasPrefix("externalApp")
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private func extensionNames(in context: NativeBrowserContext) async -> [String] {
    let profile = context.store.session.selectedSpace.profileID
    let manager = ExtensionManagerModel.shared(
      runtime: runtime, preferences: host.preferences, profileID: profile)
    for _ in 0..<20 {
      if !manager.extensions.isEmpty { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return manager.extensions.map { "\($0.name) \($0.version) enabled=\($0.enabled)" }
  }

  private func isDone(_ item: String, _ snapshot: ParitySnapshot) -> Bool {
    switch item {
    case "Downloads":
      return snapshot.downloads.contains { $0.localizedCaseInsensitiveContains("parity-note") }
    case "PDF viewer":
      return PlatformParityVerdicts.pdfViewerObservationIsComplete(
        committedURL: snapshot.committedURL, pageText: snapshot.pageText,
        downloads: snapshot.downloads)
    case "Media Session":
      return snapshot.mediaTitle.localizedCaseInsensitiveContains("parity")
    case "Picture in Picture", "Autofill addresses", "Autofill cards", "Autofill passwords":
      return false
    default:
      return snapshot.result["outcome"] != nil
    }
  }

  private func verdicts(_ check: ParityCheck, _ snapshot: ParitySnapshot) -> [[String: Any]] {
    if check.click && !snapshot.clicked && snapshot.result.isEmpty && snapshot.kinds.isEmpty
      && snapshot.sheet.isEmpty && snapshot.surfaces.isEmpty
    {
      return [
        probeRow(
          check.item, evidence: "The hidden trusted click did not land. \(describe(snapshot))")
      ]
    }
    if !snapshot.opened && !check.tolerateErrorPage {
      return [
        probeRow(check.item, evidence: "The fixture page did not load. \(describe(snapshot))")
      ]
    }
    if snapshot.scriptStalled && text(snapshot.result["outcome"]).isEmpty && snapshot.kinds.isEmpty
      && snapshot.sheet.isEmpty
    {
      return [
        probeRow(
          check.item, evidence: "The page script stalled before a result. \(describe(snapshot))")
      ]
    }
    switch check.item {
    case "Camera and microphone": return mediaRows(snapshot)
    case "Geolocation permission":
      return [
        permissionRow(
          snapshot, item: check.item, kind: "location", delegate: "GeolocationPermissionContext")
      ]
    case "Notifications permission":
      return [
        permissionRow(
          snapshot, item: check.item, kind: "notifications",
          delegate: "NotificationPermissionContext")
      ]
    case "MIDI permission":
      return [
        permissionRow(snapshot, item: check.item, kind: "midi", delegate: "MidiPermissionContext")
      ]
    case "Storage access permission":
      if snapshot.result.isEmpty, !snapshot.kinds.contains("storageAccess") {
        return [
          probeRow(
            check.item,
            evidence:
              "The click reached the iframe element, and the frame never reported a storage-access result. \(describe(snapshot))"
          )
        ]
      }
      return [
        permissionRow(
          snapshot, item: check.item, kind: "storageAccess",
          delegate: "StorageAccessPermissionContext")
      ]
    case "Clipboard permission":
      let message = text(snapshot.result["message"])
      if message.localizedCaseInsensitiveContains("not focused"),
        !snapshot.kinds.contains("clipboard")
      {
        return [
          probeRow(
            check.item,
            evidence:
              "The hidden window is not focused, so clipboard never reached a permission prompt. \(describe(snapshot))"
          )
        ]
      }
      return [
        permissionRow(
          snapshot, item: check.item, kind: "clipboard", delegate: "ClipboardPermissionContext")
      ]
    case "WebAuthn/passkeys": return [webAuthnRow(snapshot)]
    case "File System Access pickers":
      return [chooserRow(snapshot, item: check.item, delegate: "SelectFileDialog")]
    case "Web Share": return [chooserRow(snapshot, item: check.item, delegate: "ShareService")]
    case "Web Bluetooth chooser":
      return [chooserRow(snapshot, item: check.item, delegate: "BluetoothChooser")]
    case "Web USB chooser":
      return [chooserRow(snapshot, item: check.item, delegate: "UsbChooserController")]
    case "Web HID chooser":
      return [chooserRow(snapshot, item: check.item, delegate: "HidChooserController")]
    case "Web Serial chooser":
      return [chooserRow(snapshot, item: check.item, delegate: "SerialChooser")]
    case "Screen sharing picker": return [screenRow(snapshot)]
    case "Payment Request": return [paymentRow(snapshot)]
    case "Protocol handlers": return [protocolRow(snapshot)]
    case "Autofill addresses":
      return [autofillRow(snapshot, item: check.item, delegate: "Autofill address save bubble")]
    case "Autofill cards":
      return [autofillRow(snapshot, item: check.item, delegate: "Credit card save prompt")]
    case "Autofill passwords":
      return [autofillRow(snapshot, item: check.item, delegate: "Password save bubble")]
    case "WebGPU": return [featureRow(snapshot, item: check.item, delegate: "WebGPU adapter")]
    case "WebGL": return [featureRow(snapshot, item: check.item, delegate: "WebGL context")]
    case "EME/Widevine": return [emeRow(snapshot)]
    case "Widevine test stream": return [widevinePlaybackRow(snapshot)]
    case "Picture in Picture": return [pipRow(snapshot)]
    case "Media Session": return [mediaSessionRow(snapshot)]
    case "Popups/window.open": return [popupRow(snapshot)]
    case "Downloads": return [downloadRow(snapshot)]
    case "Print": return [printRow(snapshot)]
    case "PDF viewer": return [pdfRow(snapshot)]
    case "Extensions (MV3) basics": return [extensionsRow(snapshot)]
    case "PWA install": return [pwaRow(snapshot)]
    case "trackertest.org loopback": return [loopbackRow(snapshot)]
    case "HTTPS-first": return [httpsFirstRow(snapshot)]
    case "Certificate errors": return [certificateRow(snapshot)]
    default: return [probeRow(check.item, evidence: describe(snapshot))]
    }
  }

  private func mediaRows(_ snapshot: ParitySnapshot) -> [[String: Any]] {
    let audio = intValue(snapshot.result["audio"])
    let video = intValue(snapshot.result["video"])
    let delegate = "Shaar website media permission"
    let evidence = describe(snapshot)
    return [
      row(
        item: "Camera permission", passed: snapshot.kinds.contains("camera") && video > 0,
        delegate: delegate, evidence: evidence, signals: signals(snapshot)),
      row(
        item: "Microphone permission", passed: snapshot.kinds.contains("microphone") && audio > 0,
        delegate: delegate, evidence: evidence, signals: signals(snapshot)),
    ]
  }

  private func permissionRow(
    _ snapshot: ParitySnapshot, item: String, kind: String, delegate: String
  ) -> [String: Any] {
    let decision = PlatformParityVerdicts.permissionPrompt(
      kind: kind, kinds: snapshot.kinds, outcome: text(snapshot.result["outcome"]))
    return row(
      item: item, passed: decision.passed, disposition: decision.disposition,
      delegate: delegate, evidence: "\(decision.evidence) \(describe(snapshot))",
      signals: signals(snapshot))
  }

  private func webAuthnRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let created = text(snapshot.result["outcome"]) == "created"
    return row(
      item: "WebAuthn/passkeys", passed: created, delegate: "ChromeAuthenticatorRequestDelegate",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func chooserRow(
    _ snapshot: ParitySnapshot, item: String, delegate: String
  ) -> [String: Any] {
    let decision = PlatformParityVerdicts.deviceChooser(
      outcome: text(snapshot.result["outcome"]), sheet: snapshot.sheet,
      surfaces: snapshot.surfaces, browserWindows: browserWindowClassNames)
    return row(
      item: item, passed: decision.passed, disposition: decision.disposition,
      delegate: delegate, evidence: "\(decision.evidence) \(describe(snapshot))",
      signals: signals(snapshot))
  }

  private func screenRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let tracks = intValue(snapshot.result["tracks"])
    let outcome = text(snapshot.result["outcome"])
    let passed = snapshot.sheet == "desktopCapture" || (outcome == "resolved" && tracks > 0)
    return row(
      item: "Screen sharing picker", passed: passed, delegate: "DesktopCapturePicker",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func protocolRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let handled = snapshot.href.contains("/handled") || snapshot.committedURL.contains("/handled")
    let prompted = snapshot.sheet.hasPrefix("externalApp") || !snapshot.kinds.isEmpty
    return row(
      item: "Protocol handlers", passed: handled || prompted,
      delegate: "RegisterProtocolHandler permission prompt",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func autofillRow(
    _ snapshot: ParitySnapshot, item: String, delegate: String
  ) -> [String: Any] {
    let surfaced =
      !snapshot.sheet.isEmpty
      || snapshot.surfaces.contains {
        PlatformParityVerdicts.isChooserSurface($0, browserWindows: browserWindowClassNames)
      }
    return row(
      item: item, passed: surfaced, delegate: delegate, evidence: describe(snapshot),
      signals: signals(snapshot))
  }

  private func featureRow(
    _ snapshot: ParitySnapshot, item: String, delegate: String
  ) -> [String: Any] {
    row(
      item: item, passed: text(snapshot.result["outcome"]) == "resolved", delegate: delegate,
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func emeRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    row(
      item: "EME/Widevine",
      passed: text(snapshot.result["widevine"]) == "resolved"
        && text(snapshot.result["clearkey"]) == "resolved",
      delegate: "Widevine CDM", evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func widevinePlaybackRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    row(
      item: "Widevine test stream",
      passed: text(snapshot.result["outcome"]) == "playing"
        && text(snapshot.result["keySystem"]) == "com.widevine.alpha"
        && intValue(snapshot.result["currentTimeMilliseconds"]) > 0,
      delegate: "Shaka Player / Widevine test license", evidence: describe(snapshot),
      signals: signals(snapshot))
  }

  private func pipRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let passed = snapshot.pictureInPicture || text(snapshot.result["outcome"]) == "resolved"
    return row(
      item: "Picture in Picture", passed: passed, delegate: "PictureInPictureWindowController",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func mediaSessionRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    row(
      item: "Media Session", passed: snapshot.mediaTitle.contains("Parity"),
      delegate: "Shaar media session", evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func popupRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let passed = snapshot.popupURL.contains("/landed")
    return row(
      item: "Popups/window.open", passed: passed, delegate: "Shaar tab adoption for window.open",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func downloadRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let passed = snapshot.downloads.contains { $0.localizedCaseInsensitiveContains("parity-note") }
    return row(
      item: "Downloads", passed: passed, delegate: "Shaar downloads",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func printRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let decision = PlatformParityVerdicts.printSurface(
      outcome: text(snapshot.result["outcome"]), beforePrint: flag(snapshot.result["before"]),
      surfaces: snapshot.surfaces)
    return row(
      item: "Print", passed: decision.passed, disposition: decision.disposition,
      delegate: "PrintViewManager",
      evidence: "\(decision.evidence) \(describe(snapshot))", signals: signals(snapshot))
  }

  private func paymentRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let message = text(snapshot.result["message"])
    let backgroundTab =
      message.localizedCaseInsensitiveContains("background tab")
      || message.localizedCaseInsensitiveContains("preview page")
    if backgroundTab {
      return row(
        item: "Payment Request", passed: false, disposition: "probe", delegate: "PaymentRequestUI",
        evidence:
          "The hidden tab is a background tab, so Payment Request refused to show UI. \(describe(snapshot))",
        signals: signals(snapshot))
    }
    return chooserRow(snapshot, item: "Payment Request", delegate: "PaymentRequestUI")
  }

  private func pdfRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let shown = snapshot.pageText.contains("Parity PDF")
    let downloaded = snapshot.downloads.contains { $0.localizedCaseInsensitiveContains("pdf") }
    let committed = snapshot.href.contains("page.pdf") || snapshot.committedURL.contains("page.pdf")
    if !shown && !downloaded && committed {
      return row(
        item: "PDF viewer", passed: false, disposition: "probe", delegate: "Chromium PDF viewer",
        evidence:
          "The PDF URL loaded and was not downloaded. The main document did not expose the page text. \(describe(snapshot))",
        signals: signals(snapshot))
    }
    return row(
      item: "PDF viewer", passed: shown && !downloaded, delegate: "Chromium PDF viewer",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func extensionsRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let decision = PlatformParityVerdicts.extensions(
      listed: snapshot.extensions, installedMV3: snapshot.installedMV3)
    return row(
      item: "Extensions (MV3) basics", passed: decision.passed,
      disposition: decision.disposition,
      delegate: "local MV3 install",
      evidence: "\(decision.evidence) \(describe(snapshot))", signals: signals(snapshot))
  }

  private func pwaRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let prompted =
      text(snapshot.result["outcome"]) == "prompt" || snapshot.sheet == "extensionInstall"
    return row(
      item: "PWA install", passed: prompted, delegate: "AppBannerManager / beforeinstallprompt",
      evidence: describe(snapshot), signals: signals(snapshot))
  }

  private func loopbackRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let peer = text(snapshot.result["peer"])
    loopbackPeer = peer
    let passed = PlatformParityVerdicts.loopbackMapped(peer)
    let evidence =
      passed
      ? "Testing mode passes --host-resolver-rules=MAP trackertest.org 127.0.0.1. TCP peer was \(peer). \(describe(snapshot))"
      : "trackertest.org did not connect to 127.0.0.1. \(describe(snapshot))"
    return row(
      item: "trackertest.org loopback", passed: passed, disposition: passed ? "pass" : "probe",
      delegate: "--host-resolver-rules=MAP trackertest.org 127.0.0.1",
      evidence: evidence, signals: signals(snapshot))
  }

  private func httpsFirstRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let decision = PlatformParityVerdicts.httpsFirst(
      href: snapshot.href, committedURL: snapshot.committedURL, pageText: snapshot.pageText,
      outcome: text(snapshot.result["outcome"]), security: snapshot.security,
      loopbackPeer: loopbackPeer)
    return row(
      item: "HTTPS-first", passed: decision.passed, disposition: decision.disposition,
      delegate: "HttpsOnlyMode interstitial",
      evidence: "\(decision.evidence) \(describe(snapshot))", signals: signals(snapshot))
  }

  private func certificateRow(_ snapshot: ParitySnapshot) -> [String: Any] {
    let decision = PlatformParityVerdicts.certificate(
      security: snapshot.security, pageText: snapshot.pageText,
      outcome: text(snapshot.result["outcome"]),
      href: snapshot.href, committedURL: snapshot.committedURL)
    return row(
      item: "Certificate errors", passed: decision.passed, disposition: decision.disposition,
      delegate: "SSL error interstitial",
      evidence: "\(decision.evidence) \(describe(snapshot))", signals: signals(snapshot))
  }

  private func partitionRow(write: ParitySnapshot, read: ParitySnapshot) -> [String: Any] {
    let decision = PlatformParityVerdicts.partition(
      writeOpened: write.opened, readOpened: read.opened,
      writeMode: text(write.result["mode"]), writeStored: text(write.result["stored"]),
      readMode: text(read.result["mode"]), readStored: text(read.result["stored"]),
      readCookie: text(read.result["cookie"]))
    return row(
      item: "Storage partitioning / third-party cookies", passed: decision.passed,
      disposition: decision.disposition,
      delegate: "storage partitioning and third-party cookie blocking",
      evidence: "\(decision.evidence) policy=\(read.cookiesBlocked)", signals: signals(read))
  }

  private func safeBrowsingRow() -> [String: Any] {
    let enabled = preferences["safebrowsing.enabled"] ?? ""
    let decision = PlatformParityVerdicts.safeBrowsing(
      preferenceFilePresent: !preferences.isEmpty, enabled: enabled)
    return row(
      item: "Safe Browsing state", passed: decision.passed, disposition: decision.disposition,
      delegate: "Safe Browsing enabled state",
      evidence: "\(decision.evidence) \(preferenceSummary())", signals: preferences)
  }

  private func preferenceSummary() -> String {
    preferences.keys.sorted().map { "\($0)=\(preferences[$0] ?? "")" }.joined(separator: ", ")
  }

  private func row(
    item: String, passed: Bool, disposition: String = "gap", delegate: String, evidence: String,
    signals: [String: String]
  ) -> [String: Any] {
    [
      "item": item, "result": passed ? "pass" : "fail",
      "disposition": passed ? "pass" : disposition, "delegate": delegate,
      "evidence": evidence, "signals": signals,
    ]
  }

  private func inProgressRow(_ item: String) -> [String: Any] {
    [
      "item": item, "result": "in progress", "disposition": "probe", "delegate": "",
      "evidence": "This check started and has not finished.", "signals": [:],
    ]
  }

  private func probeRow(_ item: String, evidence: String) -> [String: Any] {
    row(
      item: item, passed: false, disposition: "probe", delegate: "probe",
      evidence: evidence, signals: [:])
  }

  /// Every window class the browser owns, not only the first context window.
  private var browserWindowClassNames: Set<String> {
    var names = Set(host.contexts.values.map { String(describing: type(of: $0.window)) })
    if let window = host.settingsController?.window {
      names.insert(String(describing: type(of: window)))
    }
    for signIn in host.accountSignIns.values {
      names.insert(String(describing: type(of: signIn.window)))
    }
    if let window = host.profileOnboarding?.window {
      names.insert(String(describing: type(of: window)))
    }
    if let window = host.firstRunSetup?.window {
      names.insert(String(describing: type(of: window)))
    }
    for owner in host.privateWindowOwners {
      names.insert(String(describing: type(of: owner.window)))
    }
    return names
  }

  /// A browser window class, including a subclass of one, is not a chooser.
  /// `NSOpenPanel` stays a chooser: its superclass is `NSPanel`, not a browser class.
  private func isBrowserOwnedWindow(_ window: NSWindow, browserWindows: Set<String>) -> Bool {
    var current: AnyClass? = type(of: window)
    while let cls = current, cls != NSWindow.self, cls != NSPanel.self {
      if PlatformParityVerdicts.isBrowserWindowClass(
        String(describing: cls), browserWindows: browserWindows)
      {
        return true
      }
      current = class_getSuperclass(cls)
    }
    return type(of: window) == NSWindow.self
  }

  private func recordSurface(_ name: String, on snapshot: inout ParitySnapshot) {
    if PlatformParityVerdicts.isActivationEvent(name) {
      if !snapshot.events.contains(name) { snapshot.events.append(name) }
      return
    }
    if !snapshot.surfaces.contains(name) { snapshot.surfaces.append(name) }
  }

  private func signals(_ snapshot: ParitySnapshot) -> [String: String] {
    var values: [String: String] = [
      "kinds": snapshot.kinds.joined(separator: ","),
      "sheet": snapshot.sheet,
      "surfaces": snapshot.surfaces.joined(separator: ","),
      "events": snapshot.events.joined(separator: ","),
      "security": snapshot.security,
      "href": snapshot.href,
      "committed": snapshot.committedURL,
      "downloads": snapshot.downloads.joined(separator: ","),
      "media": snapshot.mediaTitle,
      "pip": snapshot.pictureInPicture ? "yes" : "no",
      "popup": snapshot.popupURL,
      "cookies": snapshot.cookiesBlocked,
      "extensions": snapshot.extensions.joined(separator: ","),
    ]
    for (key, value) in snapshot.result {
      let rendered = text(value)
      if !rendered.isEmpty { values[key] = rendered }
    }
    return values
  }

  private func describe(_ snapshot: ParitySnapshot) -> String {
    var parts: [String] = []
    let outcome = text(snapshot.result["outcome"])
    if !outcome.isEmpty { parts.append("outcome \(outcome)") }
    for key in [
      "name", "message", "state", "widevine", "clearkey", "code", "title", "create", "peer",
    ] {
      let value = text(snapshot.result[key])
      if !value.isEmpty { parts.append("\(key) \(value)") }
    }
    if !snapshot.kinds.isEmpty {
      parts.append("permissions \(snapshot.kinds.joined(separator: ", "))")
    }
    if !snapshot.sheet.isEmpty { parts.append("sheet \(snapshot.sheet)") }
    if !snapshot.surfaces.isEmpty {
      parts.append("surfaces \(snapshot.surfaces.joined(separator: ", "))")
    }
    if !snapshot.events.isEmpty {
      parts.append("events \(snapshot.events.joined(separator: ", "))")
    }
    if !snapshot.security.isEmpty { parts.append("security \(snapshot.security)") }
    let href = snapshot.href.isEmpty ? snapshot.committedURL : snapshot.href
    if !href.isEmpty { parts.append(href) }
    let snippet = snapshot.pageText.replacingOccurrences(of: "\n", with: " ")
    if !snippet.isEmpty { parts.append(String(snippet.prefix(120))) }
    if !snapshot.downloads.isEmpty {
      parts.append("downloads \(snapshot.downloads.joined(separator: ", "))")
    }
    if !snapshot.mediaTitle.isEmpty { parts.append("media \(snapshot.mediaTitle)") }
    if snapshot.pictureInPicture { parts.append("picture in picture") }
    if !snapshot.popupURL.isEmpty { parts.append("popup \(snapshot.popupURL)") }
    if snapshot.attemptedClick {
      parts.append(snapshot.clicked ? "click landed" : "click missed")
    }
    if snapshot.scriptStalled { parts.append("script stalled") }
    return parts.joined(separator: "; ")
  }

  private func pageURL(_ check: ParityCheck) -> URL? {
    pageURL(path: check.path, base: check.base)
  }

  private func pageURL(path: String, base: ParityCheck.Base) -> URL? {
    switch base {
    case .http: return URL(string: http.absoluteString + path)
    case .https: return URL(string: https.absoluteString + path)
    case .plainHost:
      guard let port = http.port else { return nil }
      return URL(string: "http://trackertest.org:\(port)\(path)")
    case .localhost:
      guard let port = http.port else { return nil }
      return URL(string: "http://localhost:\(port)\(path)")
    }
  }

  private func waitForReady(in context: NativeBrowserContext) async -> Bool {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      let evaluation = await evaluate(in: context, "({ready: window.parityReady === true})")
      if flag(evaluation.value?["ready"]) {
        return true
      }
      if evaluation.timedOut { return false }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func click(in context: NativeBrowserContext) async -> (landed: Bool, timedOut: Bool) {
    guard let tab = selectedTabID(in: context) else { return (false, false) }
    return await withCheckedContinuation { continuation in
      let gate = EvaluateOnce()
      runtime.submitTrustedProbeClick(inTabID: tab.uuidString, elementID: "parity-action") { ok in
        guard gate.claim() else { return }
        continuation.resume(returning: (ok, false))
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
        guard gate.claim() else { return }
        continuation.resume(returning: (false, true))
      }
    }
  }

  private func evaluate(in context: NativeBrowserContext, _ script: String) async
    -> ScriptEvaluation
  {
    guard let tab = selectedTabID(in: context) else {
      return ScriptEvaluation(value: nil, timedOut: false)
    }
    let outcome: (String?, Bool) = await withCheckedContinuation { continuation in
      let gate = EvaluateOnce()
      runtime.evaluate(inTabID: tab.uuidString, script: script) { json in
        guard gate.claim() else { return }
        continuation.resume(returning: (json, false))
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
        guard gate.claim() else { return }
        continuation.resume(returning: (nil, true))
      }
    }
    guard !outcome.1 else { return ScriptEvaluation(value: nil, timedOut: true) }
    guard let data = outcome.0?.data(using: .utf8) else {
      return ScriptEvaluation(value: nil, timedOut: false)
    }
    let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    return ScriptEvaluation(value: value, timedOut: false)
  }

  private func selectedTabID(in context: NativeBrowserContext) -> UUID? {
    context.store.session.selectedPage?.tab.id
  }

  private func selectedURL(in context: NativeBrowserContext) -> URL? {
    context.store.session.selectedPage?.tab.url
  }

  private func selectedLoading(in context: NativeBrowserContext) -> Bool {
    guard let id = selectedTabID(in: context) else { return true }
    return context.engine.pages[id]?.loading != false
  }

  private func securityLevel(in context: NativeBrowserContext) -> String? {
    guard let target = context.engine.siteControlTarget else { return nil }
    let info = runtime.securityInfo(
      forTabID: target.tabID.uuidString, profileID: target.profileID.uuidString)
    return info?["level"] as? String
  }

  private func cookiePolicy(in context: NativeBrowserContext) -> String {
    let profile = context.store.session.selectedSpace.profileID.uuidString
    guard let blocked = runtime.thirdPartyCookiesBlocked(forProfileID: profile) else {
      return "unknown"
    }
    return blocked.boolValue ? "blocked" : "allowed"
  }

  private func samePage(_ left: URL, _ right: URL) -> Bool {
    left.scheme == right.scheme && left.host == right.host && left.port == right.port
      && left.path == right.path
  }

  private func trimTabs(in context: NativeBrowserContext) {
    let tabs = context.store.session.selectedSpace.tabs
    guard let keep = context.store.session.selectedSpace.selectedTabID, tabs.count > 1 else {
      return
    }
    for tab in tabs where tab.id != keep { context.store.closeTab(tab.id) }
  }

  private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let ticks = Int(seconds * 10)
    for _ in 0..<ticks {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
  }

  private func readPreferences() -> [String: String] {
    guard
      let enumerator = FileManager.default.enumerator(at: dataRoot, includingPropertiesForKeys: nil)
    else { return [:] }
    var found: [String: String] = [:]
    for case let url as URL in enumerator where url.lastPathComponent == "Preferences" {
      guard let data = try? Data(contentsOf: url),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      let excerpt = PlatformParityPreferenceEvidence.excerpt(root)
      if found.isEmpty || excerpt["safebrowsing.enabled"] != nil { found = excerpt }
    }
    return found
  }

  private func publish() {
    let hidden = NSApp.windows.allSatisfy { !$0.isVisible }
    write(
      [
        "completed": completed, "allWindowsHidden": hidden, "userAgent": userAgent,
        "preferences": preferences, "guard": SurfaceGuard.installed,
        "rows": rows,
      ],
      to: outputURL)
  }
}

private func text(_ value: Any?) -> String {
  if let value = value as? String { return value }
  if let value = value as? NSNumber { return value.stringValue }
  return ""
}

private func intValue(_ value: Any?) -> Int {
  if let value = value as? Int { return value }
  if let value = value as? NSNumber { return value.intValue }
  return 0
}

private func flag(_ value: Any?) -> Bool {
  if let value = value as? Bool { return value }
  if let value = value as? NSNumber { return value.boolValue }
  return false
}

private func write(_ value: [String: Any], to url: URL) {
  guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])
  else { return }
  try? data.write(to: url, options: .atomic)
}

private final class SurfaceRecord: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private var installed: [String] = []

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return recorded.count
  }

  var selectors: [String] {
    lock.lock()
    defer { lock.unlock() }
    return installed
  }

  func names(after index: Int) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    guard index >= 0, index < recorded.count else { return [] }
    return Array(recorded[index...])
  }

  func note(_ name: String) {
    lock.lock()
    if !recorded.contains(name) { recorded.append(name) }
    lock.unlock()
  }

  func storeInstalled(_ values: [String]) {
    lock.lock()
    if installed.isEmpty { installed = values }
    lock.unlock()
  }

  private var watching = true

  func shouldWatch() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return watching
  }

  func stopWatching() {
    lock.lock()
    watching = false
    lock.unlock()
  }
}

private enum SurfaceGuard {
  private static let record = SurfaceRecord()

  static var count: Int { record.count }
  static var installed: [String] { record.selectors }

  static func names(after index: Int) -> [String] { record.names(after: index) }

  static func note(_ name: String) { record.note(name) }

  static func startWatchdog() {
    Thread.detachNewThread {
      while record.shouldWatch() {
        Thread.sleep(forTimeInterval: 1)
        DispatchQueue.main.async {
          MainActor.assumeIsolated { hideUnexpectedWindows() }
        }
      }
    }
  }

  static func stopWatchdog() { record.stopWatching() }

  @MainActor static func hideUnexpectedWindows() {
    if let modal = NSApp.modalWindow {
      note("modal \(type(of: modal))")
      NSApp.abortModal()
    }
    for window in NSApp.windows where window.isVisible {
      note("visible \(type(of: window))")
      window.orderOut(nil)
    }
  }

  static func install() {
    guard record.selectors.isEmpty else { return }
    record.storeInstalled([
      exchange(
        NSWindow.self, #selector(NSWindow.orderFront(_:)),
        #selector(NSWindow.parityOrderFront(_:)),
        "orderFront"),
      exchange(
        NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)),
        #selector(NSWindow.parityMakeKeyAndOrderFront(_:)), "makeKeyAndOrderFront"),
      exchange(
        NSWindow.self, #selector(NSWindow.orderFrontRegardless),
        #selector(NSWindow.parityOrderFrontRegardless), "orderFrontRegardless"),
      exchange(
        NSWindow.self, #selector(NSWindow.makeKey), #selector(NSWindow.parityMakeKey), "makeKey"),
      exchange(
        NSApplication.self, NSSelectorFromString("activate"),
        NSSelectorFromString("parity_activate"), "activate"),
      exchange(
        NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:"),
        NSSelectorFromString("parity_activateIgnoringOtherApps:"), "activateIgnoringOtherApps"),
      exchange(
        NSApplication.self, #selector(NSApplication.runModal(for:)),
        #selector(NSApplication.parityRunModal(for:)), "runModal"),
      exchange(
        NSSavePanel.self, #selector(NSSavePanel.runModal), #selector(NSSavePanel.parityRunModal),
        "savePanel"),
    ])
  }

  private static func exchange(
    _ cls: AnyClass, _ original: Selector, _ replacement: Selector, _ name: String
  ) -> String {
    guard let first = class_getInstanceMethod(cls, original),
      let second = class_getInstanceMethod(cls, replacement)
    else { return "missing \(name)" }
    method_exchangeImplementations(first, second)
    return name
  }
}

extension NSWindow {
  @objc(parity_orderFront:) fileprivate func parityOrderFront(_ sender: Any?) {
    SurfaceGuard.note(String(describing: type(of: self)))
  }

  @objc(parity_makeKeyAndOrderFront:) fileprivate func parityMakeKeyAndOrderFront(
    _ sender: Any?
  ) {
    SurfaceGuard.note(String(describing: type(of: self)))
  }

  @objc(parity_orderFrontRegardless) fileprivate func parityOrderFrontRegardless() {
    SurfaceGuard.note(String(describing: type(of: self)))
  }

  @objc(parity_makeKey) fileprivate func parityMakeKey() {
    SurfaceGuard.note("event makeKey \(type(of: self))")
    // A hidden window can be key without coming on screen. Chromium's dialogs
    // abort, and later free a dangling pointer, when this call is dropped.
    guard !isVisible else { return }
    guard
      let implementation = class_getMethodImplementation(
        NSWindow.self, #selector(NSWindow.parityMakeKey))
    else { return }
    let original = unsafeBitCast(
      implementation, to: (@convention(c) (AnyObject, Selector) -> Void).self)
    original(self, #selector(NSWindow.parityMakeKey))
  }
}

extension NSApplication {
  @objc(parity_activate) fileprivate func parityActivate() {
    SurfaceGuard.note("event activate")
  }

  @objc(parity_activateIgnoringOtherApps:) fileprivate func parityActivateIgnoringOtherApps(
    _ ignore: Bool
  ) {
    SurfaceGuard.note("event activate")
  }

  @objc(parity_runModalForWindow:) fileprivate func parityRunModal(
    for window: NSWindow
  ) -> NSApplication.ModalResponse {
    SurfaceGuard.note("modal \(type(of: window))")
    return .abort
  }
}

extension NSSavePanel {
  @objc(parity_runModal) fileprivate func parityRunModal() -> NSApplication.ModalResponse {
    SurfaceGuard.note(String(describing: type(of: self)))
    return .cancel
  }
}
