import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

/// Real MV3 activation of authored pages, using hidden windows and disposable profiles only.
@MainActor
final class NativeSelectionProbe {
  let primary: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var runtime: ARCChromiumRuntime { primary.runtime }
  private var checks: [String] = []
  private var observations: [[String: Any]] = []
  private var popupHosts: [NSWindow] = []
  private var hosting: NSHostingView<AnyView>?

  init(primary: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) {
    self.primary = primary
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
    let bases = Array(store.session.spaces.prefix(3))
    let alpha = bases[0].profileID
    let beta = bases[1].profileID
    let original = store.session
    let a = BrowserTab(url: fixture.appending(path: "activation-first-\(phase)"))
    let folder = BrowserFolder(name: "Account tools", isCollapsed: true)
    let b = BrowserTab(
      url: fixture.appending(path: "activation-shared-\(phase)"), isPinned: true,
      folderID: folder.id)
    let betaTab = BrowserTab(url: fixture.appending(path: "activation-beta-\(phase)"))
    let spaces = [
      BrowserSpace(
        profileID: alpha, name: "Activation alpha", symbol: "house", tint: .ocean, tabs: [a]),
      BrowserSpace(
        profileID: alpha, name: "Activation shared", symbol: "folder", tint: .forest, tabs: [b],
        folders: [folder]),
      BrowserSpace(
        profileID: beta, name: "Activation beta", symbol: "briefcase", tint: .rose, tabs: [betaTab]),
    ]
    let secondStore = BrowserStore(
      session: try BrowserSession(
        profiles: store.session.profiles.filter { [alpha, beta].contains($0.id) }, spaces: spaces,
        selectedSpaceID: spaces[0].id))
    let owner = UUID().uuidString
    try runtime.createWindowID(owner)
    let secondary = try BrowserEngine(
      events: primary.events, windowID: owner, store: secondStore, presentsNativePanels: false)
    guard let content = runtime.hostView(forWindowID: owner) else {
      throw NativeSelectionFailure("Native selection host missing.")
    }
    let host = NSHostingView(rootView: AnyView(BrowserWindow(store: secondStore)))
    host.frame = content.bounds
    host.autoresizingMask = [.width, .height]
    content.addSubview(host)
    hosting = host
    secondary.reconcile()
    for tab in [a.id, b.id, betaTab.id] { _ = try await document(tab) }
    try expect(
      secondStore.session.selectedSpaceID == spaces[0].id
        && secondStore.session.selectedSpace.selectedTabID == a.id && store.session == original,
      "host creation of background tabs/profiles cannot steal application selection")
    var documents: [UUID: NSDictionary] = [:]
    for tab in [a.id, b.id, betaTab.id] {
      documents[tab] = try await document(tab) as NSDictionary
    }
    secondStore.showPageFind()
    secondStore.updatePageFindQuery("OrbitFindMarker")
    try await wait("secondary Find before activation") {
      secondStore.pageFind?.matchCount == 3 && secondStore.pageFind?.searching == false
    }
    let token = try await sendActivation(
      from: secondary, tabs: [b.id], windowID: owner, profile: alpha)
    try await wait("extension activates shared Space") {
      secondStore.session.selectedSpaceID == spaces[1].id
        && secondStore.session.selectedSpace.selectedTabID == b.id
    }
    observations.append(try await activationReport(token, in: b.id))
    try expect(
      secondStore.pageFind == nil
        && secondStore.session.selectedSpace.folders[0].isCollapsed == false,
      "engine activation follows the tab into its shared-profile Space and reveals its folder")
    try expect(
      store.session == original, "secondary engine activation leaves the primary model intact")
    try expect(
      runtime.find(
        inTabID: b.id.uuidString, profileID: alpha.uuidString, requestID: UUID().uuidString,
        text: "OrbitFindMarker", forward: true)
        && !runtime.find(
          inTabID: a.id.uuidString, profileID: alpha.uuidString, requestID: UUID().uuidString,
          text: "OrbitFindMarker", forward: true),
      "native selected-tab controls follow the engine-selected document")
    runtime.stopFinding(inTabID: b.id.uuidString)
    secondary.extensionPanel = nil
    try await capture(secondStore, color: .light, suffix: "light")
    try await capture(secondStore, color: .dark, suffix: "dark")
    let rapid = try await sendActivation(
      from: secondary, tabs: [a.id, b.id, a.id], windowID: owner, profile: alpha)
    try await wait("rapid engine activation") {
      secondStore.session.selectedSpaceID == spaces[0].id
        && secondStore.session.selectedSpace.selectedTabID == a.id
    }
    let rapidReport = try await activationReport(rapid, in: a.id)
    observations.append(rapidReport)
    try expect(
      rapidReport["tabID"] as? Int32 == runtime.nativeTabID(forID: a.id.uuidString),
      "rapid extension activations retain the final real native target")
    for tab in [a.id, b.id, betaTab.id] {
      try expect(
        try await document(tab) as NSDictionary == documents[tab],
        "engine activation preserves account/document identity for \(tab.uuidString)")
    }

    store.perform(.space(bases[0].id))
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    try await wait("primary Find before cross-window activation") {
      self.store.pageFind?.matchCount == 3 && self.store.pageFind?.searching == false
    }
    let primaryBefore = store.session
    let secondBefore = secondStore.session
    let primaryPopup = try await popup(primary)
    let secondaryPopup = try await popup(secondary)
    let crossWindow = try await sendActivation(
      from: secondary, tabs: [bases[2].selectedTabID!], windowID: primary.windowID, profile: alpha)
    try await wait("engine activates another application's window") {
      self.store.session.selectedSpaceID == bases[2].id
    }
    observations.append(try await activationReport(crossWindow, in: a.id))
    try expect(
      store.pageFind == nil && secondStore.session == secondBefore,
      "same-profile extension activation reaches only the target application window")
    try expect(
      runtime.view(forExtensionPopupID: primaryPopup) == nil
        && runtime.view(forExtensionPopupID: secondaryPopup) != nil,
      "target-window activation closes only its stale popup")
    try expect(
      store.session.spaces.flatMap(\.tabs) == primaryBefore.spaces.flatMap(\.tabs)
        && store.session.profiles == primaryBefore.profiles,
      "native activation changes selection without duplicating or reassigning live pages")
    try expect(
      try SessionFile(url: root.appending(path: "session.json")).load() == store.session,
      "engine-selected owning Space and tab are persisted through the normal session path")

    // A separate-profile extension can change its hidden tab strip, but cannot
    // replace the account currently presented by the primary application window.
    store.perform(.space(bases[1].id))
    store.perform(.open(fixture.appending(path: "activation-beta-background-\(phase)")))
    let temporary = store.session.selectedSpace.selectedTabID!
    _ = try await document(temporary)
    store.perform(.space(bases[0].id))
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    let find = store.pageFind?.id
    let beforeHidden = store.session
    secondStore.perform(.space(spaces[2].id))
    let hidden = try await sendActivation(
      from: secondary, tabs: [bases[1].selectedTabID!], windowID: primary.windowID, profile: beta)
    let hiddenReport = try await activationReport(hidden, in: betaTab.id)
    observations.append(hiddenReport)
    try expect(
      hiddenReport["tabID"] as? Int32
        == runtime.nativeTabID(forID: bases[1].selectedTabID!.uuidString)
        && store.session == beforeHidden && store.pageFind?.id == find,
      "real activation in an inactive profile cannot steal visible account, selection, or Find")
    secondary.extensionPanel = nil
    store.dismissPageFind()
    store.closeTab(temporary)
    try await wait("temporary background-profile tab closure") {
      !self.store.session.spaces.flatMap(\.tabs).contains { $0.id == temporary }
    }
    store.perform(.space(original.selectedSpaceID))
    try expect(runtime.closeWindowID(owner), "activation test window closes normally")
    try await wait("activation client shutdown") { secondary.isClosed }
    try expect(
      !primary.isClosed && !runtime.isQuitting,
      "activation client shutdown preserves the primary window")
  }

  private func popup(_ engine: BrowserEngine) async throws -> String {
    if case .popup(let context) = engine.extensionPanel,
      runtime.view(forExtensionPopupID: context.id) != nil
    {
      return context.id
    }
    engine.refreshExtensions()
    guard let id = engine.extensions.first(where: { $0.name == "Account isolation probe" })?.id
    else {
      throw NativeSelectionFailure("Activation extension fixture missing.")
    }
    engine.executeExtension(id)
    guard case .popup(let context) = engine.extensionPanel,
      let view = runtime.view(forExtensionPopupID: context.id)
    else { throw NativeSelectionFailure("Activation extension popup missing.") }
    let host = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
      backing: .buffered, defer: false)
    host.contentView = view
    popupHosts.append(host)
    for _ in 0..<60 {
      if await popupValue(context.id, "({ready:typeof window.probeCommand==='function'})")?["ready"]
        as? Bool == true
      {
        return context.id
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    observations.append([
      "popupReadinessFailed": context.id, "windowID": engine.windowID,
      "viewStillExists": runtime.view(forExtensionPopupID: context.id) != nil,
      "currentPanel": engine.extensionPanel?.id ?? "none",
    ])
    throw NativeSelectionFailure(
      "Activation popup document did not become ready in \(engine.windowID).")
  }

  private func sendActivation(
    from engine: BrowserEngine, tabs: [UUID], windowID: String, profile: UUID
  ) async throws -> String {
    let popup = try await popup(engine)
    let token = UUID().uuidString
    let payload: [String: Any] = [
      "action": "activate-probe", "token": token, "port": fixture.port!,
      "tabIDs": tabs.map { runtime.nativeTabID(forID: $0.uuidString) },
      "windowID": runtime.chromeWindowID(forProfileID: profile.uuidString, windowID: windowID),
    ]
    let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    // The target may be this popup's owner, so activation is expected to destroy
    // the sender. The worker stores its result; no popup acknowledgement is required.
    dispatchActivation(popup: popup, json: json)
    return token
  }

  private func dispatchActivation(popup: String, json: String) {
    runtime.evaluateProbePopupID(
      popup, script: "(()=>{chrome.runtime.sendMessage(\(json)).catch(()=>{});return {};})()"
    ) { _ in }
  }

  private func activationReport(_ token: String, in tab: UUID) async throws
    -> [String: Any]
  {
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tab.uuidString,
          script: "JSON.parse(document.documentElement.dataset.arcusisActivation || '{}')"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["token"] as? String == token
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeSelectionFailure("Activation worker report did not arrive.")
  }

  private func popupValue(_ id: String, _ expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(id, script: expression) { continuation.resume(returning: $0) }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func document(_ tab: UUID) async throws -> [String: Any] {
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tab.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account')})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1"
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeSelectionFailure("Activation fixture document not ready.")
  }

  private func capture(_ store: BrowserStore, color: ColorScheme, suffix: String) async throws {
    guard let host = hosting else { throw NativeSelectionFailure("Native selection view missing.") }
    host.rootView = AnyView(BrowserWindow(store: store).environment(\.colorScheme, color))
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw NativeSelectionFailure("Native selection capture failed.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw NativeSelectionFailure("Native selection PNG failed.")
    }
    try png.write(to: root.appending(path: "\(phase)-activation-\(suffix).png"), options: .atomic)
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeSelectionFailure("Timed out: \(label).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw NativeSelectionFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks, "observations": observations,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Authored MV3 tabs.update activation with two hidden application clients. No native physical input/focus, company accounts, Cmd-N, saved-window manifest/restoration, or engine-requested new windows.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-activation.json"), options: .atomic)
  }
}

private struct NativeSelectionFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
