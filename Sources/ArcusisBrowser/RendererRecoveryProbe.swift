import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI

private struct RendererRecoveryIdentity: Codable {
  let spaceID: UUID
  let tabID: UUID
  let profileID: UUID
  let lastDocument: String
}

/// Terminates authored renderers only. The browser process and original account pages stay alive.
@MainActor
final class RendererRecoveryProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
  private var terminations: [[String: Any]] = []
  private var previewWindow: NSWindow?

  init(
    runtime: ARCChromiumRuntime, engine: BrowserEngine, store: BrowserStore, root: URL,
    fixture: URL, phase: String
  ) {
    self.runtime = runtime
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
    let bases = Array(store.session.spaces.prefix(3))
    var originals: [UUID: NSDictionary] = [:]
    var nativeIDs: [UUID: Int32] = [:]
    for space in bases {
      let id = space.selectedTabID!
      originals[id] = try await document(id) as NSDictionary
      nativeIDs[id] = runtime.nativeTabID(forID: id.uuidString)
    }
    let file = root.appending(path: "renderer-recovery-identity.json")
    let profile = bases[0].profileID
    let tab: UUID
    let spaceID: UUID
    if phase == "initial" {
      guard store.createSpace(name: "Renderer recovery", sharingProfile: profile, tint: .ocean)
      else {
        throw RendererProbeFailure("Could not create renderer recovery fixture space.")
      }
      spaceID = store.session.selectedSpaceID
      var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
      // A different site keeps deliberate crashes away from the original 127.0.0.1 pages.
      components.host = "localhost"
      components.path = "/renderer-crash-account"
      components.query = nil
      store.perform(.open(components.url!))
      tab = store.session.selectedSpace.selectedTabID!
      _ = try await document(tab)
      _ = await evaluate(
        tab,
        """
        (()=>{document.cookie='recoveryAccount=alpha; Path=/; Max-Age=86400; SameSite=Lax';
          localStorage.setItem('recoveryAccount','alpha');return {seeded:true};})()
        """)
    } else {
      let identity = try JSONDecoder().decode(
        RendererRecoveryIdentity.self, from: Data(contentsOf: file))
      tab = identity.tabID
      spaceID = identity.spaceID
      store.perform(.space(spaceID))
      let restored = try await document(tab)
      try expect(
        identity.profileID == profile && store.rendererFailures[tab] == nil
          && restored["instance"] as? String != identity.lastDocument,
        "a tab left with a crashed renderer restores into a new document after browser restart")
      try expect(
        restored["cookie"] as? String == "recoveryAccount=alpha"
          && restored["local"] as? String == "alpha",
        "restart recovery retains the crashed tab's owning profile and account data")
    }
    let before = try await document(tab)
    let native = runtime.nativeTabID(forID: tab.uuidString)
    let allTabs = store.session.spaces.flatMap { $0.tabs.map(\.id) }
    try expect(
      !runtime.crashProbeTabID(bases[0].selectedTabID!.uuidString),
      "renderer crash hook refuses ordinary fixture pages")
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    try await wait("find before crash") { self.store.pageFind?.canMove == true }
    let failure = try await crash(tab)
    try expect(
      store.session.selectedSpaceID == spaceID && store.session.selectedSpace.selectedTabID == tab
        && store.session.spaces.flatMap { $0.tabs.map(\.id) } == allTabs
        && runtime.nativeTabID(forID: tab.uuidString) == native,
      "renderer termination retains the live tab identity, space, profile, and tab lists")
    try expect(
      store.pageFind == nil && !store.canFindCurrentPage,
      "renderer termination clears the failed document's find state")
    try await capture(
      "\(phase)-renderer-recovery.png", size: NSSize(width: 1200, height: 780), scheme: .light)
    try await capture(
      "\(phase)-renderer-recovery-compact-dark.png", size: NSSize(width: 760, height: 520),
      scheme: .dark)
    try expect(
      !runtime.reloadTabID(tab.uuidString, profileID: bases[1].profileID.uuidString),
      "native recovery rejects a different profile for the same tab")
    try expect(
      store.reloadFailedPage(failure.id),
      "native recovery action starts a reload in the selected owning profile")
    try expect(
      !store.reloadFailedPage(failure.id),
      "repeated recovery input cannot issue another in-flight reload")
    try await wait("replacement document commit") { self.store.rendererFailures[tab] == nil }
    let after = try await document(tab)
    try expect(
      after["instance"] as? String != before["instance"] as? String
        && runtime.nativeTabID(forID: tab.uuidString) == native,
      "reload creates a replacement document in the existing native tab")
    try expect(
      after["cookie"] as? String == "recoveryAccount=alpha" && after["local"] as? String == "alpha",
      "renderer reload retains the owning profile's cookies and local storage")
    try expect(
      !store.reloadFailedPage(failure.id), "a recovered document rejects an old recovery control")
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    try await wait("find after recovery") { self.store.pageFind?.canMove == true }
    try expect(true, "find works again in the replacement renderer")
    store.dismissPageFind()

    store.perform(.space(bases[1].id))
    store.showCommand()
    store.commandQuery = "another account"
    let selected = store.session.selectedSpaceID
    let backgroundFailure = try await crash(tab)
    try expect(
      store.session.selectedSpaceID == selected && store.commandIsOpen
        && store.commandQuery == "another account",
      "background renderer termination does not steal another account's selection or launcher")
    try expect(
      !store.reloadFailedPage(backgroundFailure.id)
        && !runtime.reloadTabID(tab.uuidString, profileID: profile.uuidString),
      "stale recovery and native reload cannot target a background tab")
    for base in bases {
      let id = base.selectedTabID!
      try expect(
        try await document(id) as NSDictionary == originals[id]
          && runtime.nativeTabID(forID: id.uuidString) == nativeIDs[id],
        "renderer recovery preserves unrelated live account document \(base.name)")
    }
    store.dismissCommand()
    if phase == "initial" {
      let identity = RendererRecoveryIdentity(
        spaceID: spaceID, tabID: tab, profileID: profile,
        lastDocument: after["instance"] as! String)
      try JSONEncoder().encode(identity).write(to: file, options: .atomic)
      try expect(
        store.rendererFailures[tab] != nil,
        "initial launch leaves a failed background tab for restart acceptance")
    } else {
      store.perform(.space(spaceID))
      try expect(
        store.reloadFailedPage(backgroundFailure.id),
        "background failure can be recovered after selecting its owning space")
      try await wait("background recovery commit") { self.store.rendererFailures[tab] == nil }
      _ = try await document(tab)
    }
    let sessionFile = SessionFile(url: root.appending(path: "session.json"))
    // Session saves are debounced; let the latest snapshot reach disk before comparing.
    try? await wait("saved session snapshot") { (try? sessionFile.load()) == self.store.session }
    try expect(
      try sessionFile.load() == store.session,
      "renderer failures do not corrupt or replace saved live-tab records")
    store.perform(.space(bases[0].id))
  }

  private func crash(_ tab: UUID) async throws -> RendererFailure {
    let previous = store.rendererFailures[tab]?.id
    guard runtime.crashProbeTabID(tab.uuidString) else {
      throw RendererProbeFailure("Crash target was rejected.")
    }
    try await wait("actual renderer termination") {
      self.store.rendererFailures[tab] != nil && self.store.rendererFailures[tab]?.id != previous
    }
    let failure = store.rendererFailures[tab]!
    terminations.append([
      "tabID": tab.uuidString, "status": failure.status, "exitCode": failure.exitCode,
    ])
    return failure
  }

  private func document(_ tab: UUID) async throws -> [String: Any] {
    for _ in 0..<80 {
      if engine.pages[tab]?.loading == false,
        let value = await evaluate(
          tab,
          "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem(location.hostname==='localhost'?'recoveryAccount':'account'),session:sessionStorage.getItem('account')})"
        ),
        value["fixture"] as? String == "v1"
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RendererProbeFailure("Authored renderer recovery page was not ready.")
  }

  private func evaluate(_ tab: UUID, _ expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: expression) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw RendererProbeFailure("Timed out: \(label).")
  }

  private func capture(_ name: String, size: NSSize, scheme: ColorScheme) async throws {
    let host = NSHostingView(
      rootView: BrowserWindow(store: store).environment(\.colorScheme, scheme).frame(
        width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.contentView = host
    previewWindow = window
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw RendererProbeFailure("Recovery layout could not render.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw RendererProbeFailure("Recovery layout could not encode.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw RendererProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks, "terminations": terminations,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Real renderer termination and reload of authored loopback pages, retained profiles/documents, offscreen native layouts, and restoration after graceful browser restart. Browser-process crash, real accounts, physical memory pressure, and native input are not verified.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-renderer-recovery.json"), options: .atomic)
  }
}

private struct RendererProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
