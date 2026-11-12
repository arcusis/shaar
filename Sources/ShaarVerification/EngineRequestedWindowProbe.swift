// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification

@testable import ArcusisBrowser

/// Authored page and MV3 requests through the real Chromium browser-window factory.
@MainActor
final class EngineRequestedWindowProbe {
  let host: NativeBrowserHost
  let root: URL
  let fixture: URL
  let phase: String
  private var runtime: ARCChromiumRuntime { host.events.runtime }
  private var checks: [String] = []
  private var observations: [[String: Any]] = []
  private var rollback: [String: Bool] = [:]
  private var popupCarrier: NSWindow?
  private var lastRequestPopupID: String?
  private var requestPopup: ExtensionPopupContext?
  private var declineNextRequest = false
  private var declinedRequestSeen = false

  init(host: NativeBrowserHost, root: URL, fixture: URL, phase: String) {
    self.host = host
    self.root = root
    self.fixture = fixture
    self.phase = phase
  }

  func run(alpha: NativeBrowserContext, beta: NativeBrowserContext) async throws
    -> (checks: [String], retained: UUID)
  {
    let request = host.events.onWindowRequest
    host.events.onWindowRequest = { [weak self] profile, type, userGesture in
      if self?.declineNextRequest == true {
        self?.declineNextRequest = false
        self?.declinedRequestSeen = true
        self?.observations.append(["declinedType": type, "userGesture": userGesture])
        return nil
      }
      let result = request?(profile, type, userGesture)
      self?.observations.append([
        "requestedType": type, "userGesture": userGesture,
        "managedWindow": result ?? "rejected",
      ])
      return result
    }
    defer {
      host.events.onWindowRequest = request
    }
    do {
      let retained = try await exercise(alpha: alpha, beta: beta)
      try report(error: nil)
      return (checks, retained)
    } catch {
      try? report(error: error)
      throw error
    }
  }

  private func exercise(alpha: NativeBrowserContext, beta: NativeBrowserContext) async throws
    -> UUID
  {
    let alphaTab = alpha.store.session.selectedSpace.selectedTabID!
    let betaTab = beta.store.session.selectedSpace.selectedTabID!
    let beforeAlpha = try await document(alphaTab)
    let beforeBeta = try await document(betaTab)
    let before = Set(host.contexts.keys)
    let snapshot = host.workspace.workspace
    try expect(
      runtime.onWindowRequest?(UUID().uuidString, "normal", true) == nil
        && runtime.onWindowRequest?(
          alpha.store.session.selectedSpace.profileID.uuidString, "devtools", true)
          == nil
        && host.workspace.workspace == snapshot,
      "managed window requests reject unknown profiles and unsupported types without model changes")

    let url = fixture.appending(path: "host-engine-page-\(phase)")
    let address = try literal(url.absoluteString)
    let messageToken = try literal(UUID().uuidString)
    let armed = await value(
      betaTab,
      script:
        "(()=>{window.arcusisPopupReply=null;window.arcusisPopupMessage=null;window.addEventListener('message',e=>{window.arcusisPopupMessage={source:e.source===window.arcusisChild,origin:e.origin,data:e.data};if(e.source===window.arcusisChild&&e.origin===location.origin&&e.data===\(messageToken))window.arcusisPopupReply=e.data;});const b=document.createElement('button');b.id='popup';b.textContent='Open managed popup';b.onclick=()=>{window.arcusisChild=window.open(\(address),'_blank','popup,width=820,height=620');};document.body.append(b);return {ready:b.isConnected};})()"
    )
    try expect(armed?["ready"] as? Bool == true, "authored window request fixture is armed")
    let trustedClick: Bool = await withCheckedContinuation { continuation in
      runtime.clickProbeElement(inTabID: betaTab.uuidString, elementID: "popup") {
        continuation.resume(returning: $0)
      }
    }
    try expect(trustedClick, "authored window request receives a hidden renderer user gesture")
    let page = try await createdWindow(excluding: before, url: url)
    try expect(
      observations.contains {
        $0["requestedType"] as? String == "popup"
          && $0["userGesture"] as? Bool == true
          && $0["managedWindow"] as? String != "rejected"
      },
      "authored popup request is accepted with a user gesture")
    try expect(
      observations.contains {
        $0["requestedType"] as? String == "popup"
          && $0["userGesture"] as? Bool == true
          && $0["managedWindow"] as? String != "rejected"
      },
      "authored popup request reaches the app with its user gesture")
    let pageTab = page.store.session.selectedSpace.selectedTabID!
    let pageDocument = try await document(pageTab)
    try expect(
      page.store.session.selectedSpaceID == beta.store.session.selectedSpaceID
        && page.store.session.selectedSpace.profileID == beta.store.session.selectedSpace.profileID
        && pageDocument["cookie"] as? String == "account=beta"
        && pageDocument["hasOpener"] as? Bool == true,
      "page popup retains opener Space and beta account while another profile owns focus")
    try expect(
      runtime.chromeWindowID(
        forProfileID: beta.store.session.selectedSpace.profileID.uuidString, windowID: page.nativeID
      )
        != runtime.chromeWindowID(
          forProfileID: beta.store.session.selectedSpace.profileID.uuidString,
          windowID: beta.nativeID)
        && pageTab != betaTab,
      "engine popup has a distinct managed native window and document identity")
    let postMessageResult = await value(
      pageTab,
      script:
        "(()=>{window.opener.postMessage(\(messageToken),location.origin);return {sent:true,openerClosed:window.opener.closed};})()")
    var received = false
    for _ in 0..<80 {
      if let response = await value(betaTab, script: "({token:window.arcusisPopupReply})"),
        let token = response["token"] as? String,
        try literal(token) == messageToken
      {
        received = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    if !received {
      let parent = await value(betaTab, script: "({reply:window.arcusisPopupReply,message:window.arcusisPopupMessage})")
      let child = await value(pageTab, script: "({opener:!!window.opener,url:location.href,origin:location.origin})")
      throw WindowProbeFailure(
        "Managed page popup did not preserve opener postMessage [parent=\(String(describing: parent)), child=\(String(describing: child)), send=\(String(describing: postMessageResult))].")
    }
    checks.append("managed page popup preserves opener postMessage for an authored login callback")
    _ = await value(pageTab, script: "(()=>{window.close();return {};})()")
    try await wait("script-owned popup closure") { self.host.contexts[page.id] == nil }
    try expect(
      host.workspace.workspace.window(page.id) == nil && host.contexts[beta.id] === beta,
      "script popup closure removes only its confirmed managed window")
    try expect(
      page.engine.isClosed && !page.store.reloadCurrentPage(),
      "closed engine popup cannot reload its saved tab through a retired window handle")

    var retained: UUID?
    for type in ["normal", "popup"] {
      let prior = Set(host.contexts.keys)
      let previousFocus = host.workspace.workspace.focusedWindowID
      let extensionURL = fixture.appending(path: "host-engine-extension-\(type)-\(phase)")
      let token = UUID().uuidString
      try await dispatchWindowRequest(
        from: alpha, tab: alphaTab, url: extensionURL, type: type, token: token)
      let report = try await workerReport(token, tab: alphaTab)
      observations.append(report)
      try expect(
        observations.contains {
          $0["requestedType"] as? String == type
            && $0["userGesture"] as? Bool == true
            && $0["managedWindow"] as? String != "rejected"
        },
        "chrome.windows.create \(type) reaches the app with its user gesture")
      let created = try await createdWindow(excluding: prior, url: extensionURL)
      try expect(
        NSApp.windows.allSatisfy { !$0.isVisible },
        "MV3 chrome.windows.create keeps every disposable native window hidden")
      let tab = created.store.session.selectedSpace.selectedTabID!
      let value = try await document(tab)
      try expect(
        created.store.session.selectedSpace.profileID == alpha.store.session.selectedSpace.profileID
          && value["cookie"] as? String == "account=alpha"
          && report["windowID"] as? Int32
            == runtime.chromeWindowID(
              forProfileID: alpha.store.session.selectedSpace.profileID.uuidString,
              windowID: created.nativeID)
          && (report["tabID"] as? Int32 ?? -1) >= 0,
        "MV3 chrome.windows.create \(type) reaches the matching managed alpha window")
      try expect(
        host.workspace.workspace.focusedWindowID == previousFocus,
        "background MV3 \(type) creation preserves saved focused-window identity")
      if type == "normal" {
        retained = created.id
      } else {
        runtime.closeWindowID(created.nativeID)
        try await wait("extension popup closure") { self.host.contexts[created.id] == nil }
        try expect(
          host.workspace.workspace.window(created.id) == nil,
          "extension-created popup closes without deleting its source window")
      }
    }
    alpha.engine.extensionPanel = nil
    if let popupID = lastRequestPopupID {
      try await wait("extension request popup closure") {
        self.runtime.view(forExtensionPopupID: popupID) == nil
      }
      requestPopup = nil
      lastRequestPopupID = nil
    }
    let alphaSpaceID = alpha.store.session.selectedSpaceID
    let sourceOrderBeforeSibling = alpha.store.session.selectedSpace.tabs.map(\.id)
    let siblingURL = fixture.appending(path: "host-engine-sibling-\(phase)")
    alpha.store.perform(.open(siblingURL))
    let siblingTab = alpha.store.session.selectedSpace.selectedTabID!
    _ = try await document(siblingTab)
    alpha.store.perform(.tab(space: alphaSpaceID, tab: alphaTab))
    let sourceOrderBeforeMove = alpha.store.session.selectedSpace.tabs.map(\.id)
    let sourceOrderURLsBeforeMove = alpha.store.session.selectedSpace.tabs.map {
      $0.url.absoluteString
    }
    let sourceDocumentBeforeMove = try await document(alphaTab)
    try expect(
      runtime.windowID(forTabID: siblingTab.uuidString) == alpha.nativeID
        && sourceOrderBeforeMove == sourceOrderBeforeSibling + [siblingTab]
        && sourceOrderBeforeMove.allSatisfy {
          runtime.windowID(forTabID: $0.uuidString) == alpha.nativeID
        },
      "authored sibling is live in managed source order before rejected move")
    let beforeMove = Set(host.contexts.keys)
    let moveToken = UUID().uuidString
    try await dispatchWindowRequest(
      from: alpha, tab: alphaTab, url: fixture.appending(path: "host-engine-move-\(phase)"),
      type: "normal", token: moveToken, moveExisting: true)
    var moveRejected = false
    do {
      _ = try await workerReport(moveToken, tab: alphaTab)
    } catch let failure as WindowProbeFailure {
      moveRejected = failure.message.contains("Moving managed tabs to a new engine window")
    }
    try expect(
      moveRejected, "chrome.windows.create rejects moving an existing managed tab")
    try await wait("rejected existing-tab move cleanup") {
      Set(self.host.contexts.keys) == beforeMove
    }
    rollback = [
      "ownerPreserved": runtime.windowID(forTabID: alphaTab.uuidString) == alpha.nativeID,
      "selectionPreserved": alpha.store.session.selectedSpace.selectedTabID == alphaTab,
      "identityPreserved": runtime.windowID(forTabID: alphaTab.uuidString) == alpha.nativeID,
      "modelOrderPreserved": sourceOrderBeforeMove
        == alpha.store.session.selectedSpace.tabs.map(\.id),
      "managedOwnershipPreserved": sourceOrderBeforeMove.allSatisfy {
        runtime.windowID(forTabID: $0.uuidString) == alpha.nativeID
      },
      "allOwnersPreserved": sourceOrderBeforeMove.allSatisfy {
        runtime.windowID(forTabID: $0.uuidString) == alpha.nativeID
      },
    ]
    try expect(
      rollback.values.allSatisfy { $0 },
      "rejected extension move preserves source selection, native ownership, identities, and tab order"
    )
    rollback["chromiumOrderPreserved"] = try await nativeOrderMatches(
      alpha, expectedURLs: sourceOrderURLsBeforeMove,
      selectedURL: alpha.store.session.selectedSpace.tabs.first(where: { $0.id == alphaTab })!
        .url.absoluteString)
    try expect(
      rollback["chromiumOrderPreserved"] == true,
      "Chromium confirms rejected move preserves source tab order and active identity")
    let sourceDocumentAfterMove = try await document(alphaTab)
    try expect(
      sourceDocumentAfterMove as NSDictionary == sourceDocumentBeforeMove as NSDictionary,
      "rejected extension move preserves live source document, cookie, local, and session state")
    alpha.engine.extensionPanel = nil
    alpha.store.closeTab(siblingTab)
    try await wait("authored sibling cleanup") {
      runtime.windowID(forTabID: siblingTab.uuidString) == nil
        && !alpha.store.session.spaces.flatMap(\.tabs).contains(where: { $0.id == siblingTab })
    }
    try expect(
      alpha.store.session.selectedSpace.selectedTabID == alphaTab
        && alpha.store.session.selectedSpace.tabs.map(\.id) == sourceOrderBeforeSibling,
      "probe removes only its authored sibling and keeps original selection")
    let beforeDecline = host.workspace.workspace
    let contextsBeforeDecline = Set(host.contexts.keys)
    declineNextRequest = true
    try await dispatchWindowRequest(
      from: alpha, tab: alphaTab, url: fixture.appending(path: "host-engine-declined-\(phase)"),
      type: "normal", token: UUID().uuidString)
    try await wait("declined browser request") { self.declinedRequestSeen }
    try expect(
      host.workspace.workspace == beforeDecline
        && Set(host.contexts.keys) == contextsBeforeDecline,
      "declined engine window closes without persisting a model or falling back to a visible stock window"
    )
    alpha.engine.extensionPanel = nil
    let afterAlpha = try await document(alphaTab)
    let afterBeta = try await document(betaTab)
    try expect(
      afterAlpha as NSDictionary == beforeAlpha as NSDictionary
        && afterBeta as NSDictionary == beforeBeta as NSDictionary,
      "engine-created windows preserve unrelated alpha and beta live documents and accounts")
    try expect(
      host.contexts.values.allSatisfy { !$0.window.isVisible }
        && NSApp.windows.allSatisfy { !$0.isVisible },
      "engine show requests keep every disposable managed window hidden")
    guard let retained else { throw WindowProbeFailure("No engine-created window retained.") }
    try host.workspace.workspace.validate()
    try expect(
      host.workspace.workspace.window(retained) != nil,
      "engine-created window is present in a valid managed workspace for restart")
    return retained
  }

  private func dispatchWindowRequest(
    from context: NativeBrowserContext, tab: UUID, url: URL, type: String, token: String,
    moveExisting: Bool = false
  ) async throws {
    let popup: ExtensionPopupContext
    if let existing = requestPopup,
      runtime.view(forExtensionPopupID: existing.id) != nil
    {
      popup = existing
    } else {
      switch await ProbeExtensionFixture.openPopup(on: context.engine) {
      case .unavailable:
        throw WindowProbeFailure("Window worker extension missing.")
      case .didNotOpen:
        throw WindowProbeFailure("Window worker popup missing.")
      case .opened(let opened):
        popup = opened
      }
      lastRequestPopupID = popup.id
      guard let view = runtime.view(forExtensionPopupID: popup.id) else {
        throw WindowProbeFailure("Window worker popup missing.")
      }
      let carrier = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
        backing: .buffered, defer: false)
      carrier.contentView = view
      popupCarrier = carrier
      requestPopup = popup
    }
    var ready = false
    var popupReadyState: String?
    var popupState: String?
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id, script: "({ready:typeof window.probeCommand==='function'})"
        ) { continuation.resume(returning: $0) }
      }
      popupReadyState = json
      if json?.contains("true") == true {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard ready else {
      throw WindowProbeFailure(
        "Window worker popup was not ready: \(String(describing: popupReadyState)).")
    }
    var sourceReady = false
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id,
          script: "(()=>{const t=window.arcusisSourceTab;return {ready:Number.isInteger(t&&t.id),tabID:t&&t.id,windowID:t&&t.windowId,url:t&&t.url};})()"
        ) { continuation.resume(returning: $0) }
      }
      popupState = json
      if let data = json?.data(using: .utf8),
        let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        state["ready"] as? Bool == true
      {
        sourceReady = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard sourceReady else {
      throw WindowProbeFailure("Window worker source tab was not ready: \(String(describing: popupState)).")
    }
    let request: [String: Any] = [
      "action": "create-window-probe",
      "windowID": runtime.chromeWindowID(
        forProfileID: context.store.session.selectedSpace.profileID.uuidString,
        windowID: context.nativeID),
      "url": url.absoluteString, "port": fixture.port!, "type": type, "token": token,
      "moveExisting": moveExisting,
    ]
    let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
    let encoded = try literal(json)
    let armed: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(
        popup.id, script: "(()=>{window.arcusisWindowRequest=JSON.parse(\(encoded));return true;})()"
      ) { continuation.resume(returning: $0) }
    }
    try expect(armed?.contains("true") == true, "MV3 window request fixture is armed")
    let clicked: Bool = await withCheckedContinuation { continuation in
      runtime.clickProbePopupID(popup.id, buttonTitle: "Create window") {
        continuation.resume(returning: $0)
      }
    }
    try expect(clicked, "MV3 window request receives a hidden extension-popup user gesture")
  }

  private func workerReport(_ token: String, tab: UUID) async throws -> [String: Any] {
    for _ in 0..<100 {
      if let response = await value(
        tab,
        script: "JSON.parse(document.documentElement.dataset.arcusisWindowResponse || '{}')"),
        response["token"] as? String == token,
        let reply = response["reply"] as? [String: Any],
        let error = reply["error"] as? String
      {
        throw WindowProbeFailure("Window worker rejected request: \(error)")
      }
      if let value = await value(
        tab, script: "JSON.parse(document.documentElement.dataset.arcusisWindowProbe || '{}')"),
        Self.matchesWorkerReport(value, token: token)
      {
        return value
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let response = await value(
      tab,
      script:
        "({response:document.documentElement.dataset.arcusisWindowResponse,report:document.documentElement.dataset.arcusisWindowProbe})"
    )
    throw WindowProbeFailure("Window worker report did not arrive: \(String(describing: response)).")
  }

  static func matchesWorkerReport(_ report: [String: Any], token: String) -> Bool {
    report["token"] as? String == token
  }

  private func nativeOrderMatches(
    _ context: NativeBrowserContext, expectedURLs: [String], selectedURL: String
  ) async throws -> Bool {
    let popup: ExtensionPopupContext
    switch await ProbeExtensionFixture.openPopup(on: context.engine) {
    case .unavailable:
      throw WindowProbeFailure("Order worker extension missing.")
    case .didNotOpen:
      throw WindowProbeFailure("Order worker popup missing.")
    case .opened(let opened):
      popup = opened
    }
    guard let view = runtime.view(forExtensionPopupID: popup.id) else {
      throw WindowProbeFailure("Order worker popup missing.")
    }
    let carrier = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: .borderless,
      backing: .buffered, defer: false)
    carrier.contentView = view
    popupCarrier = carrier
    var ready = false
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(
          popup.id, script: "({ready:typeof window.probeCommand==='function'})"
        ) { continuation.resume(returning: $0) }
      }
      if json?.contains("true") == true {
        ready = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard ready else { throw WindowProbeFailure("Order worker popup was not ready.") }
    let window = runtime.chromeWindowID(
      forProfileID: context.store.session.selectedSpace.profileID.uuidString,
      windowID: context.nativeID)
    guard window >= 0 else { return false }
    let encodedURLs = String(data: try JSONEncoder().encode(expectedURLs), encoding: .utf8)!
    let encodedSelectedURL = try literal(selectedURL)
    let script = """
      (()=>{window.arcusisMoveOrder=null;chrome.tabs.query({windowId:\(window)}).then(items=>{
        items.sort((a,b)=>a.index-b.index);const order=JSON.stringify(items.map(t=>t.url))===JSON.stringify(\(encodedURLs));
        const active=items.filter(t=>t.active).length===1&&items.some(t=>t.active&&t.url===\(encodedSelectedURL));
        window.arcusisMoveOrder={matches:order&&active,orderMatches:order,activeMatches:active};
      },()=>{window.arcusisMoveOrder={matches:false};});return true;})()
      """
    let _: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbePopupID(popup.id, script: script) { continuation.resume(returning: $0) }
    }
    for _ in 0..<80 {
      let json: String? = await withCheckedContinuation { continuation in
        runtime.evaluateProbePopupID(popup.id, script: "window.arcusisMoveOrder") {
          continuation.resume(returning: $0)
        }
      }
      if let data = json?.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Bool],
        let matches = value["matches"]
      {
        rollback["chromiumOrderMatches"] = value["orderMatches"]
        rollback["chromiumActiveMatches"] = value["activeMatches"]
        return matches
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func createdWindow(excluding prior: Set<UUID>, url: URL) async throws
    -> NativeBrowserContext
  {
    for _ in 0..<100 {
      if let context = host.contexts.values.first(where: {
        !prior.contains($0.id)
          && $0.store.session.selectedSpace.tabs.contains(where: { $0.url == url })
      }) {
        return context
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let managed = host.contexts.values.map { context in
      "\(context.nativeID):\(context.store.session.selectedSpace.tabs.map(\.url))"
    }.joined(separator: " | ")
    throw WindowProbeFailure(
      "Engine request did not create its managed page: \(url.lastPathComponent) [\(managed)].")
  }

  private func document(_ id: UUID) async throws -> [String: Any] {
    for _ in 0..<100 {
      if let result = await value(
        id,
        script:
          "({fixture:document.documentElement.dataset.arcusisFixture,instance:window.arcusisInstance,cookie:document.cookie,local:localStorage.getItem('account'),session:sessionStorage.getItem('account'),hasOpener:!!window.opener})"
      ),
        result["fixture"] as? String == "v1", result["instance"] as? String != nil
      {
        return result
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WindowProbeFailure("Engine-created document did not become ready.")
  }

  private func value(_ id: UUID, script: String) async -> [String: Any]? {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: id.uuidString, script: script) {
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
    throw WindowProbeFailure("Timed out: \(label).")
  }

  private func literal(_ value: String) throws -> String {
    String(data: try JSONEncoder().encode(value), encoding: .utf8)!
  }

  private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw WindowProbeFailure(message) }
    checks.append(message)
  }

  private func report(error: Error?) throws {
    try Self.reportData(
      phase: phase, checks: checks, observations: observations, rollback: rollback, error: error
    ).write(
      to: root.appending(path: "\(phase)-engine-requested-windows.json"), options: .atomic)
  }

  static func reportData(
    phase: String, checks: [String], observations: [[String: Any]], rollback: [String: Bool],
    error: Error?
  ) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "passed": error == nil, "phase": phase, "checks": checks, "observations": observations,
        "rollback": rollback,
        "error": error?.localizedDescription as Any? ?? NSNull(),
        "scope":
          "Authored page window.open and MV3 chrome.windows.create in hidden managed normal-profile windows. Does not cover real sign-in, physical focus, private sessions or third-party window flows.",
      ], options: [.prettyPrinted, .sortedKeys]
    )
  }
}

private struct WindowProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

@MainActor
func dispatchProbePopupEvaluation(_ runtime: ARCChromiumRuntime, popupID: String, script: String) {
  Task { @MainActor in
    _ = await runtime.evaluateProbePopupID(popupID, script: script)
  }
}
