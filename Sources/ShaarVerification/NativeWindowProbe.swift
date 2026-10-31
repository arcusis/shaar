import AppKit
import BrowserCore
import ChromiumBridge.Verification

@testable import ArcusisBrowser

/// Exercises native window ownership without creating a second application store or showing a window.
@MainActor
final class NativeWindowProbe {
  let runtime: ARCChromiumRuntime
  let engine: BrowserEngine
  let store: BrowserStore
  let root: URL
  let fixture: URL
  let phase: String
  private var checks: [String] = []
  private var popupPayloads: [String: [String: Any]] = [:]
  private var popupHosts: [String: NSWindow] = [:]
  private var findResults: [String: (Int32, Bool)] = [:]
  private var closedWindows: [String: Bool] = [:]
  private var observations: [String: Any] = [:]

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
    let popup = runtime.onExtensionPopup
    let find = runtime.onFindResult
    let closed = runtime.onWindowClosed
    runtime.onExtensionPopup = { [weak self] payload in
      guard let self, let window = payload["windowID"] as? String else { return }
      self.popupPayloads[window] = payload
      if window == self.runtime.primaryWindowID { popup?(payload) }
    }
    runtime.onFindResult = { [weak self] tab, token, count, active, final in
      self?.findResults[token] = (count, final)
      find?(tab, token, count, active, final)
    }
    runtime.onWindowClosed = { [weak self] id, quitting in
      self?.closedWindows[id] = quitting
      closed?(id, quitting)
    }
    defer {
      runtime.onExtensionPopup = popup
      runtime.onFindResult = find
      runtime.onWindowClosed = closed
    }
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
    let a = bases[0].profileID
    let b = bases[1].profileID
    let first = bases[0].selectedTabID!
    let primary = runtime.primaryWindowID
    var originals: [UUID: NSDictionary] = [:]
    var originalNativeIDs: [UUID: Int32] = [:]
    for space in bases {
      let id = space.selectedTabID!
      originals[id] = try await document(id) as NSDictionary
      originalNativeIDs[id] = runtime.nativeTabID(forID: id.uuidString)
    }
    store.perform(.tab(space: bases[0].id, tab: first))
    let beforeSession = store.session
    let second = UUID().uuidString
    observations["windowIDs"] = ["primary": primary, "secondary": second]
    let tabA = UUID()
    let tabB = UUID()
    try runtime.createWindowID(second)
    let firstWindow = runtime.window(forID: primary)
    let secondWindow = runtime.window(forID: second)
    try expect(
      firstWindow != nil && secondWindow != nil && firstWindow !== secondWindow,
      "two independent native windows are created without ordering either onscreen")
    var duplicate = false
    do { try runtime.createWindowID(second) } catch { duplicate = true }
    try expect(duplicate, "duplicate native window identity is rejected")
    try runtime.openTabID(
      tabA.uuidString, profileID: a.uuidString, windowID: second, url: fixture.absoluteString)
    runtime.activateTabID(tabA.uuidString)
    try attach(tabA, to: second)
    try checkPageResizes(tabA, windowID: second)
    try await checkWebStoreFit(windowID: second, profileID: b)
    runtime.activateTabID(tabA.uuidString)
    try attach(tabA, to: second)
    let alpha = try await document(tabA)
    try expect(
      alpha["cookie"] as? String == "account=alpha" && alpha["local"] as? String == "alpha"
        && alpha["session"] is NSNull,
      "another window intentionally sharing alpha's profile shares its account with a separate tab session"
    )
    try expect(
      runtime.windowID(forTabID: tabA.uuidString) == second
        && runtime.windowID(forTabID: first.uuidString) == primary
        && runtime.view(forTabID: tabA.uuidString)?.window === secondWindow,
      "tab identity and native view are bound to their owning window")
    let chromePrimary = runtime.chromeWindowID(forProfileID: a.uuidString, windowID: primary)
    let chromeSecond = runtime.chromeWindowID(forProfileID: a.uuidString, windowID: second)
    observations["chromeWindowIDs"] = [
      "primaryAlpha": chromePrimary, "secondaryAlpha": chromeSecond,
    ]
    try expect(
      chromePrimary >= 0 && chromeSecond >= 0 && chromePrimary != chromeSecond,
      "same-profile native windows have distinct real Chromium window IDs")
    var wrongWindow = false
    var wrongProfile = false
    var unknownWindow = false
    do {
      try runtime.openTabID(
        first.uuidString, profileID: a.uuidString, windowID: second, url: fixture.absoluteString)
    } catch { wrongWindow = true }
    do {
      try runtime.openTabID(
        tabA.uuidString, profileID: b.uuidString, windowID: second, url: fixture.absoluteString)
    } catch { wrongProfile = true }
    do {
      try runtime.openTabID(
        UUID().uuidString, profileID: a.uuidString, windowID: UUID().uuidString,
        url: fixture.absoluteString)
    } catch { unknownWindow = true }
    try expect(
      wrongWindow && wrongProfile && unknownWindow,
      "native creation rejects implicit window/profile reassignment and unknown-window fallback")
    try expect(
      !runtime.placeTabIDs(
        [tabA.uuidString], pinnedIDs: [], profileID: a.uuidString, windowID: primary),
      "native ordering cannot move another window's tab implicitly")
    try expect(
      runtime.placeTabIDs(
        [tabA.uuidString], pinnedIDs: [], profileID: a.uuidString, windowID: second),
      "native ordering operates inside its owning window and profile")

    engine.refreshExtensions()
    guard
      let extensionID = engine.extensions.first(where: { $0.name == "Account isolation probe" })?.id
    else {
      throw NativeWindowFailure("Native-window extension fixture missing.")
    }
    try runtime.executeExtensionID(extensionID, tabID: first.uuidString)
    let popupA = try popupID(in: primary)
    try attachPopup(popupA)
    try runtime.executeExtensionID(extensionID, tabID: tabA.uuidString)
    let popupB = try popupID(in: second)
    try attachPopup(popupB)
    try expect(
      popupA != popupB && runtime.view(forExtensionPopupID: popupA) != nil
        && runtime.view(forExtensionPopupID: popupB) != nil,
      "each window retains its own native extension popup")
    let firstPopup = try await popupContext(popupA)
    observations["primaryPopup"] = firstPopup
    let secondPopup = try await popupContext(popupB)
    observations["secondaryAlphaPopup"] = secondPopup
    try expect(
      firstPopup["windowID"] as? Int == Int(chromePrimary)
        && secondPopup["windowID"] as? Int == Int(chromeSecond),
      "extension chrome.windows.getCurrent resolves the popup's real owning window")
    try expect(
      firstPopup["account"] as? String == "alpha" && secondPopup["account"] as? String == "alpha",
      "same-profile popups share extension storage across independent windows")
    store.showPageFind()
    store.updatePageFindQuery("OrbitFindMarker")
    let secondaryFind = UUID().uuidString
    try expect(
      runtime.find(
        inTabID: tabA.uuidString, profileID: a.uuidString, requestID: secondaryFind,
        text: "Disposable test data only.", forward: true),
      "the selected tab in another window can start its own native find session")
    try await wait("simultaneous window find results") {
      self.store.pageFind?.canMove == true && self.findResults[secondaryFind]?.1 == true
    }
    try expect(
      store.pageFind?.matchCount == 3 && findResults[secondaryFind]?.0 == 1,
      "simultaneous native find requests retain separate result tokens and counts")
    try expect(
      runtime.view(forExtensionPopupID: popupA) == nil
        && runtime.view(forExtensionPopupID: popupB) != nil,
      "opening Find in one window closes only that window's popup")
    runtime.stopFinding(inTabID: tabA.uuidString)
    store.movePageFind(forward: true)
    try await wait("primary find after secondary stop") { self.store.pageFind?.canMove == true }
    try expect(
      store.pageFind?.matchCount == 3,
      "stopping another window's find leaves the primary find usable")
    store.dismissPageFind()

    try runtime.openTabID(
      tabB.uuidString, profileID: b.uuidString, windowID: second, url: fixture.absoluteString)
    runtime.activateTabID(tabB.uuidString)
    try attach(tabB, to: second)
    let beta = try await document(tabB)
    try expect(
      beta["cookie"] as? String == "account=beta" && beta["local"] as? String == "beta",
      "another profile in the second window retains its separate account")
    try expect(
      runtime.view(forExtensionPopupID: popupB) == nil,
      "changing the selected tab closes its own stale popup")
    for _ in 0..<3 {
      runtime.activateTabID(tabA.uuidString)
      try attach(tabA, to: second)
      runtime.activateTabID(tabB.uuidString)
      try attach(tabB, to: second)
    }
    let switchedAlpha = try await document(tabA)
    let switchedBeta = try await document(tabB)
    try expect(
      switchedAlpha as NSDictionary == alpha as NSDictionary
        && switchedBeta as NSDictionary == beta as NSDictionary,
      "profile switching inside another window retains both live documents and accounts")
    runtime.activateTabID(tabA.uuidString)
    try attach(tabA, to: second)
    runtime.activateTabID(first.uuidString)
    try expect(
      runtime.reloadTabID(tabA.uuidString, profileID: a.uuidString),
      "each window keeps its selected tab independently of another window's activation")
    let reloaded = try await document(tabA, differentFrom: alpha["instance"] as? String)
    try expect(
      reloaded["cookie"] as? String == "account=alpha"
        && runtime.windowID(forTabID: tabA.uuidString) == second,
      "secondary reload preserves its profile and window binding")
    runtime.clearActiveTab(inWindowID: second)
    try expect(
      !runtime.reloadTabID(tabA.uuidString, profileID: a.uuidString),
      "clearing a window rejects stale selected-tab controls for that window")
    try expect(
      runtime.find(
        inTabID: first.uuidString, profileID: a.uuidString,
        requestID: UUID().uuidString, text: "OrbitFindMarker", forward: true),
      "clearing another window preserves primary selected-tab controls")
    runtime.stopFinding(inTabID: first.uuidString)
    runtime.activateTabID(tabB.uuidString)
    try attach(tabB, to: second)
    try runtime.executeExtensionID(extensionID, tabID: tabB.uuidString)
    let betaPopup = try popupID(in: second)
    try attachPopup(betaPopup)
    let betaContext = try await popupContext(betaPopup)
    observations["secondaryBetaPopup"] = betaContext
    try expect(
      betaContext["account"] as? String == "beta",
      "secondary profile's popup reads only its beta extension storage")
    try expect(
      betaContext["windowID"] as? Int
        == Int(runtime.chromeWindowID(forProfileID: b.uuidString, windowID: second)),
      "secondary beta popup resolves its own profile-specific Chromium window")
    try expect(
      store.session == beforeSession,
      "secondary native activity does not add or alter primary saved tabs")
    try expect(
      runtime.closeWindowID(second), "ordinary close requests only the selected native window")
    try await wait("secondary native window close") { self.closedWindows[second] != nil }
    try expect(
      closedWindows[second] == false && !runtime.isQuitting
        && runtime.window(forID: primary) != nil,
      "closing another window does not mark the entire browser as quitting")
    try expect(
      runtime.find(
        inTabID: first.uuidString, profileID: a.uuidString,
        requestID: UUID().uuidString, text: "OrbitFindMarker", forward: true),
      "closing another window preserves primary selected-tab controls")
    runtime.stopFinding(inTabID: first.uuidString)
    try expect(
      runtime.window(forID: second) == nil && runtime.hostView(forWindowID: second) == nil
        && runtime.nativeTabID(forID: tabA.uuidString) == -1
        && runtime.nativeTabID(forID: tabB.uuidString) == -1
        && runtime.view(forExtensionPopupID: betaPopup) == nil,
      "confirmed native window closure releases only its own tabs and popup")
    var retired = false
    do { try runtime.createWindowID(second) } catch { retired = true }
    try expect(
      retired && !runtime.closeWindowID(second),
      "closed native identities cannot revive stale window controls")
    for space in bases {
      let id = space.selectedTabID!
      try expect(
        try await document(id) as NSDictionary == originals[id]
          && runtime.nativeTabID(forID: id.uuidString) == originalNativeIDs[id],
        "secondary window lifecycle preserves unrelated account document \(space.name)")
    }
    store.perform(.open(fixture.appending(path: "native-window-close")))
    let temporary = store.session.selectedSpace.selectedTabID!
    _ = try await document(temporary)
    store.closeTab(temporary)
    try await wait("ordinary primary close after secondary window closure") {
      self.runtime.nativeTabID(forID: temporary.uuidString) == -1
        && self.store.session.closedTabs.contains { $0.id == temporary }
    }
    try expect(
      true, "normal primary close and recovery recording still work after another window closes")
    store.perform(.tab(space: bases[0].id, tab: first))
    try expect(
      try SessionFile(url: root.appending(path: "session.json")).load() == store.session,
      "native window experiment preserves the primary session persistence contract")
  }

  private func attach(_ tab: UUID, to window: String) throws {
    guard let host = runtime.hostView(forWindowID: window),
      let page = runtime.view(forTabID: tab.uuidString)
    else { throw NativeWindowFailure("Native window view missing.") }
    for child in host.subviews { child.removeFromSuperview() }
    page.removeFromSuperview()
    page.frame = host.bounds
    page.autoresizingMask = [.width, .height]
    host.addSubview(page)
  }

  private func checkPageResizes(_ tab: UUID, windowID: String) throws {
    guard let window = runtime.window(forID: windowID),
      let host = runtime.hostView(forWindowID: windowID),
      let page = runtime.view(forTabID: tab.uuidString)
    else { throw NativeWindowFailure("Native window page missing for resize check.") }
    let original = window.frame
    var resized = original
    resized.size.width += 137
    resized.size.height += 83
    window.setFrame(resized, display: false)
    host.layoutSubtreeIfNeeded()
    page.layoutSubtreeIfNeeded()
    try expect(
      page.frame == host.bounds,
      "live Chromium page frame follows resized native window host bounds")
    window.setFrame(original, display: false)
    host.layoutSubtreeIfNeeded()
  }

  /// The fixture fixes its body at 1280 px, like the Chrome Web Store.
  private func checkWebStoreFit(windowID: String, profileID: UUID) async throws {
    var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
    components.path = "/web-store-fit"
    let tab = UUID()
    try runtime.openTabID(
      tab.uuidString, profileID: profileID.uuidString, windowID: windowID,
      url: components.url!.absoluteString)
    runtime.activateTabID(tab.uuidString)
    try attach(tab, to: windowID)
    guard let page = runtime.view(forTabID: tab.uuidString) else {
      throw NativeWindowFailure("Web Store fit page missing.")
    }
    let height = page.frame.height
    page.setFrameSize(NSSize(width: 1000, height: height))
    let narrow = try await fitLayout(tab, "narrow") { $0.width >= 1280 && $0.overflow == 0 }
    try expect(
      narrow.width <= 1282,
      "a narrow page card zooms the fixed-width store out just enough to fit without overflow")
    page.setFrameSize(NSSize(width: 600, height: height))
    let clamped = try await fitLayout(tab, "clamped") { (894...897).contains($0.width) }
    try expect(
      clamped.overflow > 0,
      "the store fit zoom stops at its readable minimum on a very narrow page card")
    page.setFrameSize(NSSize(width: 1400, height: height))
    _ = try await fitLayout(tab, "wide") { $0.width == 1400 && $0.overflow == 0 }
    try expect(true, "a page card wide enough for the store restores full zoom")
    runtime.closeTabID(tab.uuidString)
    try await wait("Web Store fit tab close") {
      self.runtime.nativeTabID(forID: tab.uuidString) == -1
    }
  }

  private func fitLayout(
    _ tab: UUID, _ label: String, until ready: ((width: Int, overflow: Int)) -> Bool
  ) async throws -> (width: Int, overflow: Int) {
    var last: [String: Any] = [:]
    for _ in 0..<50 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tab.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,width:innerWidth,overflow:document.documentElement.scrollWidth-document.documentElement.clientWidth})"
        ) { continuation.resume(returning: $0) }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        last = value
      }
      if last["fixture"] as? String == "web-store-fit", let width = last["width"] as? Int,
        let overflow = last["overflow"] as? Int, ready((width, overflow))
      {
        observations["webStoreFit:\(label)"] = last
        return (width, overflow)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    observations["webStoreFit:\(label)"] = last
    throw NativeWindowFailure("Web Store fit did not settle: \(label).")
  }

  private func popupID(in window: String) throws -> String {
    guard let id = popupPayloads[window]?["id"] as? String else {
      throw NativeWindowFailure("Window-owned popup missing.")
    }
    return id
  }

  private func attachPopup(_ id: String) throws {
    guard let view = runtime.view(forExtensionPopupID: id) else {
      throw NativeWindowFailure("Popup view missing.")
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = view
    popupHosts[id] = window
  }

  private func popupContext(_ id: String) async throws -> [String: Any] {
    var ready = false
    for _ in 0..<60 {
      if await popupValue(id, "({ready:typeof window.probeCommand==='function'})")?["ready"]
        as? Bool == true
      {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    observations["popupReady:\(id)"] = ready
    guard ready else { throw NativeWindowFailure("Extension popup document not ready: \(id).") }
    _ = await popupValue(
      id,
      """
      (()=>{window.nativeWindowProbe=null;Promise.all([chrome.windows.getCurrent({populate:true}),chrome.storage.local.get('account')]).then(([w,s])=>{
        window.nativeWindowProbe={windowID:w.id,account:s.account,tabs:w.tabs.map(t=>({id:t.id,active:t.active}))};
        }).catch(e=>window.nativeWindowProbe={error:String(e)});return {};})()
      """)
    for _ in 0..<60 {
      if let value = await popupValue(id, "window.nativeWindowProbe || {pending:true}"),
        value["pending"] as? Bool != true
      {
        guard value["error"] == nil else {
          throw NativeWindowFailure("Extension window query failed: \(value)")
        }
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeWindowFailure("Extension window query timed out: \(id).")
  }

  private func popupValue(_ id: String, _ expression: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(id, script: expression) { continuation.resume(returning: $0) }
    }
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func document(_ id: UUID, differentFrom old: String? = nil) async throws -> [String: Any]
  {
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: id.uuidString,
          script:
            "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account'),session:sessionStorage.getItem('account')})"
        ) {
          continuation.resume(returning: $0)
        }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["fixture"] as? String == "v1", let instance = value["instance"] as? String,
        instance != old
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeWindowFailure("Authored native-window page not ready.")
  }

  private func wait(_ label: String, until ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NativeWindowFailure("Timed out: \(label).")
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw NativeWindowFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "checks": checks,
        "observations": observations, "closedWindows": closedWindows,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Native multiwindow API only, authored pages and component extension, with no visible windows. Application Cmd-N, per-window stores/menus, saved window restoration, native focus/input, and close cancellation are not implemented or verified by this probe.",
      ], options: [.prettyPrinted, .sortedKeys]
    ).write(to: root.appending(path: "\(phase)-native-windows.json"), options: .atomic)
  }
}

private struct NativeWindowFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
