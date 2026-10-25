import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import SwiftUI

@MainActor
final class ExternalAppConsentProbe {
  static let mode = "external-app-consent-only"
  static let scope =
    "Owned loopback external-app consent with native no-launch resolver; no operating-system handler launch, company account or release claim."
  static let checkNames = [
    "handlerAvailable", "noLaunchGuardEnabled", "profileAApproved", "profileBApproved",
    "denyWithoutLaunch", "replayIgnored", "unpresentedDenied", "profileSwitchDenied",
    "navigationDenied", "sameURLReloadDenied", "tabCloseDenied", "windowCloseDenied",
    "foreignWindowDenied", "engineQuitDenied", "allUnremembered",
  ]

  struct Evidence {
    let runID: String
    var checks = Array(repeating: false, count: 15)
    var approvedRequests = 0
    var launchCount = 0
    var deniedRequests = 0
    var targetByApproval: [String] = []
    var cleanup: [String: Any] = [:]
    var complete = false
  }

  private let engine: BrowserEngine
  private let store: BrowserStore
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let runtime: ARCChromiumRuntime
  private var evidence: Evidence
  private var observedIDs: Set<String> = []
  private var deniedIDs: Set<String> = []
  private var approvalIDs: [String] = []
  private var callbackInstrumented = false
  private var captureWindow: NSWindow?
  private var secondaryWindowID: String?
  private var secondaryEngine: BrowserEngine?
  private var secondaryStore: BrowserStore?
  private var secondaryHost: NSHostingView<BrowserWindow>?
  private var leavePendingForQuit = false
  private var quitRequestID: String?

  init(engine: BrowserEngine, store: BrowserStore, root: URL, fixture: URL, phase: String) throws {
    self.engine = engine
    self.store = store
    self.root = root
    self.fixture = fixture
    self.phase = phase
    runtime = engine.runtime
    evidence = try Self.loadRunIdentity(root: root, phase: phase)
  }

  func run() async throws -> Evidence {
    do {
      try await exercise()
      return evidence
    } catch {
      throw error
    }
  }

  func prepareForQuit() {
    leavePendingForQuit = true
  }

  var currentEvidence: Evidence { evidence }

  func auditAfterQuit(engineClosed: Bool, primaryWindowClosed: Bool) -> Evidence {
    closeSecondaryWindow()
    let routerCount = engine.events.router.clients.count
    let pending = store.externalAppRequests.count + (secondaryStore?.externalAppRequests.count ?? 0)
    let quitDenied =
      leavePendingForQuit && quitRequestID != nil
      && !store.externalAppRequests.contains(where: { $0.id == quitRequestID })
    if quitDenied && deniedIDs.insert(quitRequestID!).inserted { evidence.deniedRequests += 1 }
    evidence.cleanup = [
      "mode": Self.mode, "scope": Self.scope, "phase": phase, "runID": evidence.runID,
      "engineClosed": engineClosed, "primaryWindowClosed": primaryWindowClosed,
      "routerClientCount": routerCount, "pendingRequests": pending,
      "passed": engineClosed && primaryWindowClosed && routerCount == 0 && pending == 0,
    ]
    let audits = evidence.targetByApproval.compactMap { audit($0) }
    evidence.launchCount = audits.map { $0.count }.max() ?? 0
    evidence.checks[13] =
      quitDenied && engineClosed && primaryWindowClosed && pending == 0
      && audits.count == 2 && audits.allSatisfy { $0.count == 2 }
    evidence.checks[14] = audits.count == 2 && audits.allSatisfy(\.allUnremembered)
    evidence.complete =
      evidence.checks.allSatisfy { $0 }
      && evidence.approvedRequests == 2 && evidence.launchCount == 2
      && evidence.deniedRequests >= 6
      && (evidence.cleanup["passed"] as? Bool == true)
    return evidence
  }

  private func exercise() async throws {
    let scheme = try handlerScheme()
    evidence.checks[0] = true
    let targets = ["\(scheme):probe-one@invalid.example", "\(scheme):probe-two@invalid.example"]
    guard let initial = audit(targets[0]), initial.count == 0,
      initial.matchingCount == 0, initial.allUnremembered
    else { throw failure("Native no-launch audit unavailable or nonzero before request.") }
    evidence.checks[1] = true
    instrumentCallback()

    let spaces = store.session.spaces
    guard spaces.count >= 2 else { throw failure("Two isolated fixture profiles are missing.") }
    for index in 0..<2 {
      let space = spaces[index]
      store.dismissPageFind()
      store.perform(.space(space.id))
      guard let tab = store.session.selectedSpace.selectedTabID else {
        throw failure("Selected fixture tab is missing.")
      }
      try await ready(tab)
      let target = targets[index]
      let request = try await trigger(tab, target: target)
      try await waitPresented(request.id)
      if index == 0 { try await captureConsent(request) }
      let auditURL = target
      store.resolveExternalApp(request.id, accepted: true)
      store.sheetDidDismiss()
      try await waitRemoved(request.id)
      guard let audit = audit(auditURL), audit.count == index + 1,
        audit.matchingCount == 1, audit.allUnremembered
      else { throw failure("Approval did not reach guarded native resolver.") }
      evidence.targetByApproval.append(auditURL)
      approvalIDs.append(request.id)
      evidence.approvedRequests += 1
      evidence.launchCount = audit.count
      evidence.checks[index + 2] = true
    }
    for id in approvalIDs { replay(id) }
    guard evidence.targetByApproval.allSatisfy({ audit($0)?.count == 2 }) else {
      throw failure("Store, event, or native resolver replay changed launch audit.")
    }
    evidence.checks[4] = try await denial(targets[0], action: .direct)
    evidence.checks[5] =
      evidence.checks[4]
      && evidence.targetByApproval.allSatisfy { audit($0)?.count == 2 }
    evidence.checks[6] = try await denial(targets[0], action: .unpresented)
    evidence.checks[7] = try await denial(targets[0], action: .profileSwitch)
    evidence.checks[8] = try await denial(targets[0], action: .navigation)
    evidence.checks[9] = try await denial(targets[0], action: .reload)
    evidence.checks[10] = try await denial(targets[0], action: .tabClose)
    evidence.checks[11] = try await secondaryWindowDenial(targets[0], foreignAttempt: false)
    evidence.checks[12] = try await secondaryWindowDenial(targets[0], foreignAttempt: true)
    guard evidence.targetByApproval.allSatisfy({ audit($0)?.count == 2 }) else {
      throw failure("A denial or replay changed native launch count.")
    }
    try await prepareEngineQuit(target: targets[0])
  }

  private enum DenialAction {
    case direct, unpresented, profileSwitch, navigation, reload, tabClose
  }

  private func denial(_ target: String, action: DenialAction) async throws -> Bool {
    let space = store.session.spaces[0]
    store.perform(.space(space.id))
    store.perform(.open(fixture.appending(path: "external-consent-\(evidence.deniedRequests)")))
    guard let tab = store.session.selectedSpace.selectedTabID else {
      throw failure("Fixture tab missing.")
    }
    try await ready(tab)
    if action == .unpresented { store.showDownloads() }
    let request = try await trigger(tab, target: target)
    switch action {
    case .direct:
      try await waitPresented(request.id)
      store.resolveExternalApp(request.id, accepted: false)
    case .unpresented:
      guard store.sheet?.isConsent == false else {
        throw failure("Existing modal did not retain presentation.")
      }
      store.resolveExternalApp(request.id, accepted: true)
    case .profileSwitch:
      guard let other = store.session.spaces.dropFirst().first else {
        throw failure("Second profile missing.")
      }
      store.perform(.space(other.id))
    case .navigation:
      _ = try await gesture(tab, script: "location.href='/external-navigation';true")
    case .reload:
      _ = try await gesture(tab, script: "location.reload();true")
    case .tabClose:
      runtime.closeTabID(tab.uuidString)
    }
    try await waitRemoved(request.id)
    try recordDenied(request.id)
    if action == .unpresented {
      store.sheet = nil
      store.presentNextConsent()
    }
    replay(request.id)
    if action != .tabClose { runtime.closeTabID(tab.uuidString) }
    return audit(target)?.count == 2
  }

  private func trigger(_ tab: UUID, target: String) async throws -> ExternalAppRequest {
    guard store.session.selectedSpace.selectedTabID == tab,
      runtime.windowID(forTabID: tab.uuidString) == engine.windowID
    else { throw failure("Selected profile and owned tab did not reconcile.") }
    let encoded = target.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
    let clicked = await withCheckedContinuation { continuation in
      runtime.evaluateProbeUserGesture(
        inTabID: tab.uuidString,
        script:
          "(()=>{let a=document.getElementById('external-consent-probe');if(!a){a=document.createElement('a');a.id='external-consent-probe';a.textContent='Open fixture';document.body.append(a)}a.href='\(encoded)';a.click();return true})()"
      ) { continuation.resume(returning: $0) }
    }
    guard clicked == "true" || clicked == "1" else {
      throw failure("Authored gesture did not run.")
    }
    for _ in 0..<100 {
      if let request = store.externalAppRequests.first(where: { $0.tabID == tab }),
        observedIDs.contains(request.id), request.matches(store.session)
      {
        return request
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Real external-protocol callback did not create a current request.")
  }

  private func ready(_ tab: UUID) async throws {
    for _ in 0..<100 {
      if runtime.windowID(forTabID: tab.uuidString) == engine.windowID,
        let loaded = await evaluate(
          tab,
          "document.readyState==='complete' && document.documentElement.dataset.arcusisFixture==='v1'"
        ) as? Bool,
        loaded
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Owned fixture document did not become ready.")
  }

  private func waitPresented(_ id: String) async throws {
    for _ in 0..<100 {
      if store.sheet?.id == "external-\(id)",
        store.externalAppRequests.contains(where: { $0.id == id })
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Real external consent did not become presented.")
  }

  private func waitRemoved(_ id: String) async throws {
    for _ in 0..<100 {
      if !store.externalAppRequests.contains(where: { $0.id == id }) { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("External consent request did not resolve or become stale.")
  }

  private func captureConsent(_ request: ExternalAppRequest) async throws {
    let view = ExternalAppConsent(store: store, request: request)
    try await capture(
      view, size: NSSize(width: 496, height: 620), name: "\(phase)-external-app-consent-normal.png",
      appearance: .aqua)
    try await capture(
      view, size: NSSize(width: 440, height: 320),
      name: "\(phase)-external-app-consent-compact.png", appearance: .aqua)
    try await capture(
      view, size: NSSize(width: 496, height: 620), name: "\(phase)-external-app-consent-dark.png",
      appearance: .darkAqua)
  }

  private func capture<V: View>(
    _ view: V, size: NSSize, name: String, appearance: NSAppearance.Name
  ) async throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.appearance = NSAppearance(named: appearance)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    captureWindow = window
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      throw failure("Consent capture render failed.")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw failure("Consent capture encode failed.")
    }
    try png.write(to: root.appending(path: name), options: .atomic)
    window.close()
    captureWindow = nil
  }

  private func secondaryWindowDenial(_ target: String, foreignAttempt: Bool) async throws -> Bool {
    let space = store.session.spaces[0]
    guard space.selectedTabID != nil else { throw failure("Primary fixture tab missing.") }
    let id = UUID().uuidString
    let isolated = BrowserSpace(
      profileID: space.profileID, name: "Consent secondary", symbol: "square", tint: .ocean,
      tabs: [BrowserTab(url: fixture.appending(path: "secondary-consent"))])
    let secondaryStore = BrowserStore(
      session: try BrowserSession(
        profiles: store.session.profiles.filter { $0.id == space.profileID }, spaces: [isolated],
        selectedSpaceID: isolated.id))
    try runtime.createWindowID(id)
    secondaryWindowID = id
    let second = try BrowserEngine(
      events: engine.events, windowID: id, store: secondaryStore, presentsNativePanels: false)
    secondaryEngine = second
    self.secondaryStore = secondaryStore
    guard let content = runtime.hostView(forWindowID: id) else {
      throw failure("Owned secondary host missing.")
    }
    let hosting = NSHostingView(rootView: BrowserWindow(store: secondaryStore))
    hosting.frame = content.bounds
    hosting.autoresizingMask = [.width, .height]
    content.addSubview(hosting)
    secondaryHost = hosting
    second.reconcile()
    try await readySecondary(isolated.selectedTabID!, engine: second)
    let request = try await triggerSecondary(
      isolated.selectedTabID!, target: target, engine: second, store: secondaryStore)
    for _ in 0..<100 {
      if secondaryStore.sheet?.id == "external-\(request.id)" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard secondaryStore.sheet?.id == "external-\(request.id)" else {
      throw failure("Secondary consent was not presented.")
    }
    if foreignAttempt {
      engine.events.resolveExternalApp(request.id, windowID: engine.windowID, accepted: true)
      guard secondaryStore.externalAppRequests.contains(where: { $0.id == request.id }) else {
        throw failure("Foreign decision consumed owner request.")
      }
      secondaryStore.resolveExternalApp(request.id, accepted: false)
      try await waitSecondaryRemoved(request.id, secondaryStore)
    } else {
      runtime.closeWindowID(id)
      try await waitSecondaryRemoved(request.id, secondaryStore)
    }
    try recordDenied(request.id)
    replaySecondary(request.id, owner: id, store: secondaryStore)
    if foreignAttempt { runtime.closeWindowID(id) }
    for _ in 0..<100 {
      if second.isClosed && runtime.window(forID: id) == nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard second.isClosed, runtime.window(forID: id) == nil,
      !engine.events.router.clients.contains(where: { $0.windowID == id }),
      secondaryStore.externalAppRequests.isEmpty
    else { throw failure("Secondary window cleanup did not complete.") }
    let unchanged = audit(target)?.count == 2
    closeSecondaryWindow()
    return unchanged
  }

  private func prepareEngineQuit(target: String) async throws {
    let space = store.session.spaces[0]
    store.perform(.space(space.id))
    guard let tab = store.session.selectedSpace.selectedTabID else {
      throw failure("Quit fixture tab missing.")
    }
    try await ready(tab)
    let request = try await trigger(tab, target: target)
    try await waitPresented(request.id)
    quitRequestID = request.id
    leavePendingForQuit = true
  }

  private func instrumentCallback() {
    guard !callbackInstrumented else { return }
    callbackInstrumented = true
    let old = runtime.onExternalAppRequest
    runtime.onExternalAppRequest = { [weak self] payload in
      if let id = payload["id"] as? String { self?.observedIDs.insert(id) }
      old?(payload)
    }
  }

  private func replay(_ id: String) {
    store.resolveExternalApp(id, accepted: true)
    engine.events.resolveExternalApp(id, windowID: engine.windowID, accepted: true)
    runtime.resolveExternalAppRequestID(id, accepted: true)
  }

  private func replaySecondary(_ id: String, owner: String, store: BrowserStore) {
    store.resolveExternalApp(id, accepted: true)
    engine.events.resolveExternalApp(id, windowID: owner, accepted: true)
    runtime.resolveExternalAppRequestID(id, accepted: true)
  }

  private func recordDenied(_ id: String) throws {
    guard observedIDs.contains(id), deniedIDs.insert(id).inserted else {
      throw failure("Denied request was not a distinct native callback.")
    }
    evidence.deniedRequests = deniedIDs.count
  }

  private func handlerScheme() throws -> String {
    for scheme in ["mailto", "tel", "facetime", "webcal"] {
      if let url = URL(string: "\(scheme):probe@invalid.example"),
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
      {
        return scheme
      }
    }
    throw failure("No installed external-protocol handler available.")
  }

  private func audit(_ target: String) -> (count: Int, matchingCount: Int, allUnremembered: Bool)? {
    guard let value = runtime.probeExternalAppLaunchAudit(forURL: target) as? [String: Any],
      let count = value["count"] as? Int, let matching = value["matchingCount"] as? Int,
      let unremembered = value["allUnremembered"] as? Bool
    else { return nil }
    return (count, matching, unremembered)
  }

  private func evaluate(_ tab: UUID, _ script: String) async -> Any? {
    let value: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    guard let data = value?.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  private func gesture(_ tab: UUID, script: String) async throws -> Bool {
    let value: String? = await withCheckedContinuation { continuation in
      runtime.evaluateProbeUserGesture(inTabID: tab.uuidString, script: script) {
        continuation.resume(returning: $0)
      }
    }
    return value == "true" || value == "1"
  }

  private func readySecondary(_ tab: UUID, engine: BrowserEngine) async throws {
    for _ in 0..<100 {
      if runtime.windowID(forTabID: tab.uuidString) == engine.windowID,
        await evaluate(
          tab,
          "document.readyState==='complete' && document.documentElement.dataset.arcusisFixture==='v1'"
        ) as? Bool == true
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Secondary fixture did not become ready.")
  }

  private func triggerSecondary(
    _ tab: UUID, target: String, engine: BrowserEngine, store: BrowserStore
  ) async throws -> ExternalAppRequest {
    let escaped = target.replacingOccurrences(of: "'", with: "\\'")
    _ = try await gesture(
      tab,
      script:
        "(()=>{let a=document.createElement('a');a.id='external-consent-probe';a.href='\(escaped)';a.textContent='Open fixture';document.body.append(a);a.click();return true})()"
    )
    for _ in 0..<100 {
      if let request = store.externalAppRequests.first(where: { $0.tabID == tab }) {
        return request
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Secondary native request did not arrive.")
  }

  private func waitSecondaryRemoved(_ id: String, _ store: BrowserStore) async throws {
    for _ in 0..<100 {
      if !store.externalAppRequests.contains(where: { $0.id == id }) { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw failure("Secondary request did not resolve.")
  }

  private func closeSecondaryWindow() {
    if let secondaryWindowID, runtime.window(forID: secondaryWindowID) != nil {
      runtime.closeWindowID(secondaryWindowID)
    }
    secondaryHost = nil
    secondaryEngine = nil
    secondaryStore = nil
    self.secondaryWindowID = nil
  }

  private static func loadRunIdentity(root: URL, phase: String) throws -> Evidence {
    let url = root.appending(path: "external-app-consent-run.json")
    if phase == "initial" {
      try? FileManager.default.removeItem(
        at: root.appending(path: "initial-external-app-consent.json"))
      try? FileManager.default.removeItem(
        at: root.appending(path: "restart-external-app-consent.json"))
    } else {
      try? FileManager.default.removeItem(
        at: root.appending(path: "restart-external-app-consent.json"))
    }
    if phase == "initial" {
      let runID = UUID().uuidString.uppercased()
      let data = try JSONSerialization.data(
        withJSONObject: ["schema": 1, "runID": runID], options: [.sortedKeys])
      try data.write(to: url, options: .atomic)
      return Evidence(runID: runID)
    }
    guard let data = try? Data(contentsOf: url),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(metadata.keys) == ["schema", "runID"],
      let schema = metadata["schema"] as? NSNumber,
      CFGetTypeID(schema) != CFBooleanGetTypeID(), schema == 1,
      let runID = metadata["runID"] as? String,
      UUID(uuidString: runID)?.uuidString == runID
    else { throw ProbeFailure("External consent run identity is malformed or missing.") }
    guard
      let priorData = try? Data(
        contentsOf: root.appending(path: "initial-external-app-consent.json")),
      let prior = try? JSONSerialization.jsonObject(with: priorData) as? [String: Any],
      prior["runID"] as? String == runID
    else { throw ProbeFailure("External consent phases have inconsistent run identity.") }
    return Evidence(runID: runID)
  }

  private func failure(_ text: String) -> ProbeFailure { ProbeFailure(text) }
}

private struct ProbeFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
