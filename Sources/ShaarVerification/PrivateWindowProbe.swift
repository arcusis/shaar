import AppKit
import BrowserCore
import ChromiumBridge.Verification
import CryptoKit
import Foundation

@MainActor
final class PrivateWindowProbe {
  private let runtime: ARCChromiumRuntime
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let sourceA: String
  private let sourceB: String
  private let normalTab: String
  private let runID: String
  private let normalSession: BrowserSession
  private var checks: [String: Bool] = [:]
  private var historyPathDigest: String?
  private var historyEntryCount = 0
  private var historyQuerySucceeded = false
  private var productWorkspaceSHA256: String?
  private var productScreenshotSHA256: String?
  private var productRendererScreenshotSHA256: String?
  private var productRendererViewportAudit: [String: Any] = [:]
  private var productRendererCaptureOutcome = "not-attempted"
  private var productLifecycleBlocker: String?
  private var stage = "preflight"
  private var lastDocumentAudit: [String: Any] = [:]
  private var privateEvaluationShape = "unavailable"
  private var normalSelectionBefore: [AnyHashable: Any] = [:]
  private var normalSelectionAudit: [String: Any] = [:]
  private var privateWindows: [String] = []
  private var privateWindowContexts: [String: String] = [:]
  private var privateContexts: [String] = []
  private var expectedPrivateCallbackOwners: [String: String] = [:]
  private var privateChangedTabs: Set<String> = []
  private var privateSelectedTabs: Set<String> = []
  private var privateClosedTabs: Set<String> = []
  private var privateClosedWindows: Set<String> = []
  private var privateWindowCallbackOwners: [String: String] = [:]
  private var previousTabChanged: ((String, String, String, Bool, Bool, Bool) -> Void)?
  private var previousTabClosed: ((String) -> Void)?
  private var previousPrivateTabChanged:
    (@MainActor @Sendable (String, String, String, String, String, Bool, Bool, Bool) -> Void)?
  private var previousPrivateTabSelected: (@MainActor @Sendable (String, String, String) -> Void)?
  private var previousPrivateTabClosed: (@MainActor @Sendable (String, String, String) -> Void)?
  private var previousPrivateWindowClosed: (@MainActor @Sendable (String, String) -> Void)?
  nonisolated(unsafe) private var expectedRegularRouteIDs: Set<String> = []
  nonisolated(unsafe) private var regularCallbackContamination = false

  static let mode = "private-window-owned-engine-fixture"
  static let checkNames = [
    "freshMarkedRoot", "sourceProfileAccepted", "unknownSourceRejected", "otrSourceRejected",
    "malformedContextRejected",
    "normalProfileIDCollisionRejected", "normalWindowIDCollisionRejected",
    "normalTabIDCollisionRejected",
    "multipleTabsShareNativePrivateWindow", "privateSelectionAndNativeViewsOwned",
    "privateNavigationReloadBackForward", "privateCallbacksUseOwnersWithoutRegularContamination",
    "invalidPrivateOperationsRejected", "privateTabCloseConfirmedAndStaleRejected",
    "privateWindowCloseCallbackOwnerRouted", "repeatedPrivateWindowCloseRejected",
    "normalFactoriesRejectPrivateIdentities", "releaseWhileOwnedWindowRejected",
    "sameSourcePendingCallbacksShareOTR",
    "releaseDuringPendingWindowCreationRejected",
    "nativePrivateTabOwnedByActiveWebContents",
    "hiddenWindowsRemainUnordered",
    "sameSourceWindowsShareCookiesAndLocalStorage", "sameSourceSessionStorageIsTabLocal",
    "differentSourceContextsIsolated", "closingOneSharedWindowRetainsOther",
    "closeCancellationRetainsOwnership",
    "normalDocumentAndStorageRemainLive", "normalHistoryIncludesAuthoredVisit",
    "normalHistoryExcludesPrivateVisitsBeforeClose", "normalHistoryExcludesPrivateVisitsAfterClose",
    "lastCloseReopenClearsPrivateData", "normalSelectionUnchanged", "staleContextRejected",
    "closedWindowRejected", "cleanupChildrenClosed", "cleanupContextsRetired",
    "productHostOwnsPrivateNativeWindow", "productCommandTUsesPrivateOpaqueSearch",
    "productCommandLTargetsCurrentPrivateTab", "productPrivateFocusUsesOwnedTab",
    "productPrivateNavigationReloadBackForwardCallbacks",
    "productSameSourceWindowsShareContext", "productDifferentSourceWindowsIsolateContext",
    "productCancelledCloseRetainsOwner", "productNormalHistoryExcludesPrivateVisit",
    "productCancelledQuitRetainsLivePrivateLease",
    "productNativeQuitCancellationReturned", "productCancelledQuitRestoredRuntimeState",
    "productCancelledQuitRetainedPrivateWindow", "productCancelledQuitRetainedPrivateContext",
    "productCancelledQuitRetainedNormalWindow",
    "productFinalCloseAfterCancelledQuitReleasesLease",
    "productFinalPrivateWindowCloseRequestedWhileQuitAndReleasedAfterConfirmation",
    "productWorkspaceBytesUnchanged", "productWorkspaceBytesUnchangedAfterClose",
    "productFinalCloseReleasesOwners", "productWeakStoreReleasedAfterConfirmedClose",
    "productWeakHostingReleasedAfterConfirmedClose",
    "productBeforeUnloadUsesRendererUserActivation",
    "productNativeCDPHoldConfirmedPending",
    "productNativeBeforeUnloadHandlerFired",
    "productBeforeUnloadRemovedBeforeFinalFixtureQuit",
    "productCancelledQuitRetiresOnlyConfirmedPrivateLease",
  ]

  init(
    runtime: ARCChromiumRuntime, root: URL, fixture: URL, phase: String,
    sourceA: String, sourceB: String, normalTab: String, runID: String,
    normalSession: BrowserSession
  ) {
    self.runtime = runtime
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.sourceA = sourceA
    self.sourceB = sourceB
    self.normalTab = normalTab
    self.runID = runID
    self.normalSession = normalSession
  }

  func run() async throws -> [String] {
    do {
      let result = try await exercise()
      restorePrivateCallbackAudit()
      return result
    } catch {
      await cleanupOwnedObjects()
      restorePrivateCallbackAudit()
      if productLifecycleBlocker?.isEmpty != false {
        productLifecycleBlocker = error.localizedDescription
      }
      for name in Self.checkNames where name.hasPrefix("product") {
        if checks[name] == nil { checks[name] = false }
      }
      try? writeReport(runID: runID)
      throw error
    }
  }

  private func exercise() async throws -> [String] {
    let marker = runID.lowercased()
    installPrivateCallbackAudit()
    stage = "normal-fixture-preflight"
    let contextA = UUID().uuidString.uppercased()
    let contextB = UUID().uuidString.uppercased()
    let contextC = UUID().uuidString.uppercased()
    let normalPath = "/private-window-normal-\(marker)"
    guard
      root.path.hasPrefix(
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"),
      (try? String(contentsOf: root.appending(path: ".arcusis-probe"), encoding: .utf8))
        == "arcusis-engine-probe-v1\n"
    else {
      throw PrivateWindowFailure(
        "Private fixture root is not positively marked disposable storage.")
    }
    checks["freshMarkedRoot"] = true

    try await waitForFixture(tabID: normalTab, privateTab: false)
    normalSelectionBefore = runtime.normalProbeSelectionAudit(forTabID: normalTab)
    let normalBefore = try await evaluateNormal(
      normalTab,
      "({cookie:document.cookie, local:localStorage.getItem('account'), session:sessionStorage.getItem('account'), instance:window.arcusisInstance})"
    )
    guard normalBefore["cookie"] as? String == "account=alpha",
      normalBefore["local"] as? String == "alpha"
    else {
      throw PrivateWindowFailure(
        "Normal fixture account state was not established before private work.")
    }

    checks["sameSourcePendingCallbacksShareOTR"] = await beginReentrantPair(
      contextA, UUID().uuidString.uppercased(), sourceA)
    if phase == "initial" {
      try await authorNormalHistory(path: normalPath)
    }
    checks["normalHistoryIncludesAuthoredVisit"] = try await history(
      sourceA, contains: normalPath)
    checks["sourceProfileAccepted"] = try await begin(contextA, sourceA)
    checks["unknownSourceRejected"] = try await rejectedContext(
      UUID().uuidString.uppercased(), "unknown-source")
    checks["otrSourceRejected"] = try await rejectedAsOTR(contextA)
    checks["malformedContextRejected"] = try await rejectedContext("bad", sourceA)
    checks["normalProfileIDCollisionRejected"] = try await rejectedContext(sourceA, sourceA)

    let w1 = UUID().uuidString.uppercased()
    let w2 = UUID().uuidString.uppercased()
    let t1 = UUID().uuidString.uppercased()
    let t2 = UUID().uuidString.uppercased()
    try open(w1, contextA, t1, fixture.appending(path: "private-window-\(marker)-a").absoluteString)
    try open(w2, contextA, t2, fixture.appending(path: "private-window-\(marker)-b").absoluteString)
    privateWindows += [w1, w2]
    privateContexts.append(contextA)
    guard runtime.selectPrivateTabID(t1, windowID: w1, contextID: contextA) else {
      throw PrivateWindowFailure("Private first tab could not be selected.")
    }
    try await waitForFixture(tabID: t1, privateTab: true, contextID: contextA)
    guard runtime.selectPrivateTabID(t2, windowID: w2, contextID: contextA) else {
      throw PrivateWindowFailure("Private second tab could not be selected.")
    }
    try await waitForFixture(tabID: t2, privateTab: true, contextID: contextA)
    let t5 = UUID().uuidString.uppercased()
    expectedPrivateCallbackOwners[t5] = "\(contextA)|\(w2)"
    expectedRegularRouteIDs.insert(t5)
    try runtime.openPrivateTabID(
      t5, windowID: w2, contextID: contextA,
      url: fixture.appending(path: "private-window-\(marker)-d").absoluteString)
    guard runtime.selectPrivateTabID(t5, windowID: w2, contextID: contextA) else {
      throw PrivateWindowFailure("Private added tab could not be selected.")
    }
    try await waitForFixture(tabID: t5, privateTab: true, contextID: contextA)
    checks["multipleTabsShareNativePrivateWindow"] =
      runtime.privateProbeAudit(forContextID: contextA)?["windowCount"] as? Int == 2
      && runtime.privateProbeAudit(forContextID: contextA)?["tabCount"] as? Int == 3
      && runtime.view(forPrivateTabID: t5, windowID: w2, contextID: contextA) != nil
    checks["releaseWhileOwnedWindowRejected"] = !runtime.releasePrivateContextID(contextA)
    let normalProfileRejected = await rejectedNormalProfile(contextA)
    checks["normalFactoriesRejectPrivateIdentities"] =
      rejectedNormalWindow(w1)
      && rejectedNormalTab(t1) && normalProfileRejected
    checks["privateSelectionAndNativeViewsOwned"] =
      runtime.selectPrivateTabID(
        t5, windowID: w2, contextID: contextA)
      && runtime.window(forPrivateWindowID: w2, contextID: contextA) != nil
      && runtime.hostView(forPrivateWindowID: w2, contextID: contextA) != nil
      && runtime.view(forPrivateTabID: t5, windowID: w2, contextID: contextA) != nil
    checks["privateNavigationReloadBackForward"] = try await exerciseNavigation(
      tab: t5, window: w2, context: contextA, marker: marker)
    checks["invalidPrivateOperationsRejected"] =
      !runtime.selectPrivateTabID(t5, windowID: w1, contextID: contextA)
      && !runtime.navigatePrivateTabID(
        t5, windowID: w2, contextID: contextA, url: "javascript:1")
      && runtime.view(forPrivateTabID: t5, windowID: w1, contextID: contextA) == nil
    checks["normalWindowIDCollisionRejected"] =
      rejectedOpen(
        window: runtime.primaryWindowID, context: contextA, tab: UUID().uuidString.uppercased())
      && rejectedOpen(
        window: sourceA, context: contextA, tab: UUID().uuidString.uppercased())
      && rejectedOpen(
        window: w1, context: contextA, tab: UUID().uuidString.uppercased())
      && rejectedOpen(
        window: contextA, context: contextA, tab: UUID().uuidString.uppercased())
    checks["normalTabIDCollisionRejected"] =
      rejectedOpen(window: UUID().uuidString.uppercased(), context: contextA, tab: normalTab)
      && rejectedOpen(window: UUID().uuidString.uppercased(), context: contextA, tab: sourceA)
      && rejectedOpen(window: UUID().uuidString.uppercased(), context: contextA, tab: w1)
      && rejectedOpen(window: UUID().uuidString.uppercased(), context: contextA, tab: contextA)
    checks["releaseDuringPendingWindowCreationRejected"] =
      runtime.privateProbeAudit(forContextID: contextA)?["pendingReleaseRejected"] as? Bool == true
      && runtime.privateProbeAudit(forContextID: contextA)?["pendingWindowCount"] as? Int == 0
    checks["hiddenWindowsRemainUnordered"] =
      (runtime.privateProbeAudit(forContextID: contextA)?["allWindowsHidden"] as? Bool) == true
    checks["nativePrivateTabOwnedByActiveWebContents"] =
      runtime.privateProbeAudit(forContextID: contextA)?["allTabsInNativeProfileBrowser"] as? Bool
      == true
      && runtime.privateProbeAudit(forContextID: contextA)?["allTabsAttachedToHostView"] as? Bool
        == true
      && runtime.privateProbeAudit(forContextID: contextA)?["allWindowsUsePrivateActiveProfile"]
        as? Bool == true
      && runtime.privateProbeAudit(forContextID: contextA)?["allWindowsDisplayOwnedWebContents"]
        as? Bool == true
    let secret = UUID().uuidString.lowercased()
    try await setPrivate(t1, cookie: secret, storage: secret, session: secret)
    try await waitUntil(t2) { $0["local"] as? String == secret }
    let shared = try await readPrivate(t2)
    checks["sameSourceWindowsShareCookiesAndLocalStorage"] =
      shared["cookie"] as? String == "private=\(secret)" && shared["local"] as? String == secret
    checks["sameSourceSessionStorageIsTabLocal"] = shared["session"] is NSNull
    stage = "private-sharing-verified"
    let cancelledClose = runtime.attemptCancelledPrivateProbeCloseID(w1)
    let afterCancelledClose = try await readPrivate(t1)
    checks["closeCancellationRetainsOwnership"] =
      cancelledClose && afterCancelledClose["local"] as? String == secret
      && (runtime.privateProbeAudit(forContextID: contextA)?["windowCount"] as? Int == 2)

    checks["sourceProfileAccepted"] =
      checks["sourceProfileAccepted"] == true
      && (runtime.privateProbeAudit(forContextID: contextA)?["contextIsPrivate"] as? Bool == true)
    checks["unknownSourceRejected"] = checks["unknownSourceRejected"] == true
    checks["otrSourceRejected"] = checks["otrSourceRejected"] == true

    checks["normalHistoryExcludesPrivateVisitsBeforeClose"] = try await history(
      sourceA, excludes: "private-window-\(marker)", retaining: normalPath)

    let sourceBAccepted = try await begin(contextB, sourceB)
    checks["sourceProfileAccepted"] = checks["sourceProfileAccepted"] == true && sourceBAccepted
    let w3 = UUID().uuidString.uppercased()
    let t3 = UUID().uuidString.uppercased()
    try open(w3, contextB, t3, fixture.appending(path: "private-window-\(marker)-c").absoluteString)
    privateWindows.append(w3)
    privateContexts.append(contextB)
    guard runtime.selectPrivateTabID(t3, windowID: w3, contextID: contextB) else {
      throw PrivateWindowFailure("Isolated private tab could not be selected.")
    }
    try await waitForFixture(tabID: t3, privateTab: true, contextID: contextB)
    let isolated = try await readPrivate(t3)
    checks["differentSourceContextsIsolated"] =
      isolated["cookie"] as? String == "" && isolated["local"] is NSNull

    checks["closingOneSharedWindowRetainsOther"] = await close(w1)
    privateWindows.removeAll { $0 == w1 }
    checks["privateWindowCloseCallbackOwnerRouted"] =
      privateClosedWindows.contains(w1)
      && privateWindowCallbackOwners[w1] == "\(contextA)|\(w1)"
      && privateClosedTabs.contains(t1)
    let repeatedWindowClose = await withCheckedContinuation { continuation in
      runtime.closePrivateWindowID(w1, contextID: contextA) { continuation.resume(returning: $0) }
    }
    checks["repeatedPrivateWindowCloseRejected"] = !repeatedWindowClose
    let tabCloseConfirmed = await closeTab(t5, window: w2, context: contextA)
    let repeatedTabCloseRejected = await closeTab(t5, window: w2, context: contextA) == false
    checks["privateTabCloseConfirmedAndStaleRejected"] =
      tabCloseConfirmed
      && repeatedTabCloseRejected && privateClosedTabs.contains(t5)
      && runtime.view(forPrivateTabID: t5, windowID: w2, contextID: contextA) == nil
      && runtime.privateProbeAudit(forContextID: contextA)?["tabCount"] as? Int == 1
    checks["privateCallbacksUseOwnersWithoutRegularContamination"] =
      privateChangedTabs.isSuperset(of: [t1, t2, t5])
      && privateSelectedTabs.isSuperset(of: [t5, t2])
      && privateClosedTabs.isSuperset(of: [t1, t5])
      && !regularCallbackContamination
    let closedTabResult: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivateProbeTabID(t1, script: "true") { continuation.resume(returning: $0) }
    }
    checks["closedWindowRejected"] = closedTabResult == nil
    let audit = runtime.privateProbeAudit(forContextID: contextA)
    let retained = try await readPrivate(t2)
    checks["closingOneSharedWindowRetainsOther"] =
      checks["closingOneSharedWindowRetainsOther"] == true && audit?["windowCount"] as? Int == 1
      && retained["local"] as? String == secret

    let normalAfter = try await evaluateNormal(
      normalTab,
      "({cookie:document.cookie, local:localStorage.getItem('account'), session:sessionStorage.getItem('account'), instance:window.arcusisInstance})"
    )
    checks["normalDocumentAndStorageRemainLive"] =
      normalAfter["cookie"] as? String == normalBefore["cookie"] as? String
      && normalAfter["local"] as? String == normalBefore["local"] as? String
      && normalAfter["session"] as? String == normalBefore["session"] as? String
      && normalAfter["instance"] as? String == normalBefore["instance"] as? String
    var staleRejected = false
    do {
      try runtime.createPrivateWindowID(
        UUID().uuidString, contextID: UUID().uuidString,
        tabID: UUID().uuidString, url: fixture.absoluteString)
    } catch { staleRejected = true }
    checks["staleContextRejected"] = staleRejected
    let retainedValue = try await readPrivate(t2)
    checks["closedWindowRejected"] =
      checks["closedWindowRejected"] == true && retainedValue["local"] as? String == secret

    for window in privateWindows {
      if !(await close(window)) {
        throw PrivateWindowFailure("Owned private window did not close cleanly.")
      }
    }
    privateWindows.removeAll()
    for context in privateContexts {
      if !runtime.releasePrivateContextID(context) {
        throw PrivateWindowFailure("Private OTR context did not retire after final native close.")
      }
    }
    privateContexts.removeAll()

    guard try await begin(contextC, sourceA) else {
      throw PrivateWindowFailure("Reopened source context was not created.")
    }
    let w4 = UUID().uuidString.uppercased()
    let t4 = UUID().uuidString.uppercased()
    try open(
      w4, contextC, t4, fixture.appending(path: "private-window-\(marker)-reopen").absoluteString)
    privateWindows.append(w4)
    privateContexts.append(contextC)
    try await waitForFixture(tabID: t4, privateTab: true, contextID: contextC)
    let reopened = try await readPrivate(t4)
    checks["lastCloseReopenClearsPrivateData"] =
      reopened["cookie"] as? String == "" && reopened["local"] is NSNull
      && reopened["session"] is NSNull
    if !(await close(w4)) || !runtime.releasePrivateContextID(contextC) {
      throw PrivateWindowFailure("Reopened private fixture did not clean up.")
    }
    privateWindows.removeAll()
    privateContexts.removeAll()
    checks["normalSelectionUnchanged"] = normalSelectionRetained()
    checks["normalHistoryExcludesPrivateVisitsAfterClose"] = try await history(
      sourceA, excludes: "private-window-\(marker)", retaining: normalPath)
    checks["cleanupChildrenClosed"] = privateWindows.isEmpty && privateContexts.isEmpty
    checks["cleanupContextsRetired"] =
      runtime.privateProbeAudit(forContextID: contextA) == nil
      && runtime.privateProbeAudit(forContextID: contextB) == nil
      && runtime.privateProbeAudit(forContextID: contextC) == nil
    let product = try await PrivateProductHostProbe(
      runtime: runtime, root: root, fixture: fixture, phase: phase,
      runID: runID, normalSession: normalSession, sourceA: sourceA, sourceB: sourceB
    ).run()
    for (name, passed) in product.checks { checks[name] = passed }
    productWorkspaceSHA256 = product.workspaceSHA256
    productScreenshotSHA256 = product.screenshotSHA256
    productRendererScreenshotSHA256 = product.rendererScreenshotSHA256
    productRendererViewportAudit = product.rendererViewportAudit
    productRendererCaptureOutcome = product.rendererCaptureOutcome
    productLifecycleBlocker = product.lifecycleBlocker
    try writeReport(runID: runID)
    guard Self.checkNames.allSatisfy({ checks[$0] == true }), !Self.checkNames.isEmpty else {
      let failed = Self.checkNames.filter { checks[$0] != true }.joined(separator: ", ")
      throw PrivateWindowFailure("Private window fixture failed required checks: \(failed).")
    }
    return Self.checkNames.map { "Private fixture: \($0)" }
  }

  private func cleanupOwnedObjects() async {
    var remainingWindows: [String] = []
    for window in privateWindows {
      if !(await close(window)) { remainingWindows.append(window) }
    }
    privateWindows = remainingWindows
    var remainingContexts: [String] = []
    for context in privateContexts {
      if privateWindows.isEmpty && runtime.releasePrivateContextID(context) {
        continue
      }
      remainingContexts.append(context)
    }
    privateContexts = remainingContexts
    checks["cleanupChildrenClosed"] = privateWindows.isEmpty
    checks["cleanupContextsRetired"] = privateContexts.isEmpty
  }

  private func begin(_ id: String, _ source: String) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
      runtime.createPrivateContextID(id, sourceProfileID: source) { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: success)
        }
      }
    }
  }

  private func beginReentrantPair(_ first: String, _ second: String, _ source: String) async -> Bool
  {
    await withCheckedContinuation { continuation in
      var results: [String: Bool] = [:]
      var sharedProfileToken: String?
      var firstReleaseRetainedSibling = false
      let complete: (String, Bool) -> Void = { identity, success in
        guard success else {
          results[identity] = false
          if results.count == 2 { continuation.resume(returning: false) }
          return
        }
        let other = identity == first ? second : first
        let before = self.runtime.privateProbeAudit(forContextID: identity)
        let otherBefore = self.runtime.privateProbeAudit(forContextID: other)
        let profileToken = before?["profileToken"] as? String
        if sharedProfileToken == nil { sharedProfileToken = profileToken }
        let sharedProfile =
          profileToken != nil && profileToken == sharedProfileToken
          && (otherBefore == nil || otherBefore?["profileToken"] as? String == sharedProfileToken)
        let released = self.runtime.releasePrivateContextID(identity)
        let otherAfter = self.runtime.privateProbeAudit(forContextID: other)
        if otherBefore != nil {
          firstReleaseRetainedSibling =
            released && sharedProfile
            && otherAfter?["profileToken"] as? String == sharedProfileToken
            && otherAfter?["profileAlive"] as? Bool == true
            && otherAfter?["contextIsPrivate"] as? Bool == true
        }
        results[identity] =
          released && sharedProfile
          && (otherBefore == nil || firstReleaseRetainedSibling)
        if results.count == 2 { continuation.resume(returning: results.values.allSatisfy { $0 }) }
      }
      runtime.createPrivateContextID(first, sourceProfileID: source) { success, _ in
        complete(first, success)
      }
      runtime.createPrivateContextID(second, sourceProfileID: source) { success, _ in
        complete(second, success)
      }
    }
  }

  private func rejectedContext(_ id: String, _ source: String) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
      runtime.createPrivateContextID(id, sourceProfileID: source) { success, _ in
        continuation.resume(returning: !success)
      }
    }
  }

  private func rejectedAsOTR(_ context: String) async throws -> Bool {
    // The bridge accepts only loaded regular Profile IDs; context identity itself cannot resolve as a source.
    try await rejectedContext(context, context)
  }

  private func open(_ window: String, _ context: String, _ tab: String, _ url: String) throws {
    expectedPrivateCallbackOwners[tab] = "\(context)|\(window)"
    expectedRegularRouteIDs.insert(tab)
    try runtime.createPrivateWindowID(window, contextID: context, tabID: tab, url: url)
    privateWindowContexts[window] = context
  }

  private func rejectedOpen(window: String, context: String, tab: String) -> Bool {
    do {
      try runtime.createPrivateWindowID(
        window, contextID: context, tabID: tab, url: fixture.absoluteString)
      return false
    } catch { return true }
  }

  private func rejectedNormalTab(_ tab: String) -> Bool {
    do {
      try runtime.openTabID(
        tab, profileID: sourceA, windowID: runtime.primaryWindowID,
        url: fixture.absoluteString)
      return false
    } catch { return true }
  }

  private func rejectedNormalWindow(_ window: String) -> Bool {
    do {
      try runtime.createWindowID(window)
      return false
    } catch { return true }
  }

  private func rejectedNormalProfile(_ profile: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.loadProfileID(profile) { continuation.resume(returning: $0 != nil) }
    }
  }

  private func close(_ window: String) async -> Bool {
    guard let context = privateWindowContexts[window] else { return false }
    let closed = await withCheckedContinuation { continuation in
      runtime.closePrivateWindowID(window, contextID: context) {
        continuation.resume(returning: $0)
      }
    }
    if closed { privateWindowContexts.removeValue(forKey: window) }
    return closed
  }

  private func installPrivateCallbackAudit() {
    previousTabChanged = runtime.onTabChanged
    previousTabClosed = runtime.onTabClosed
    previousPrivateTabChanged = runtime.onPrivateTabChanged
    previousPrivateTabSelected = runtime.onPrivateTabSelected
    previousPrivateTabClosed = runtime.onPrivateTabClosed
    previousPrivateWindowClosed = runtime.onPrivateWindowClosed
    runtime.onPrivateTabChanged = { context, window, tab, _, _, _, _, _ in
      if self.expectedPrivateCallbackOwners[tab] == "\(context)|\(window)" {
        self.privateChangedTabs.insert(tab)
      }
    }
    runtime.onPrivateTabSelected = { context, window, tab in
      if self.expectedPrivateCallbackOwners[tab] == "\(context)|\(window)" {
        self.privateSelectedTabs.insert(tab)
      }
    }
    runtime.onPrivateTabClosed = { context, window, tab in
      if self.expectedPrivateCallbackOwners[tab] == "\(context)|\(window)" {
        self.privateClosedTabs.insert(tab)
      }
    }
    runtime.onPrivateWindowClosed = { context, window in
      self.privateClosedWindows.insert(window)
      self.privateWindowCallbackOwners[window] = "\(context)|\(window)"
    }
    runtime.onTabChanged = { tab, url, title, loading, canGoBack, canGoForward in
      if self.expectedRegularRouteIDs.contains(tab) { self.regularCallbackContamination = true }
      self.previousTabChanged?(tab, url, title, loading, canGoBack, canGoForward)
    }
    runtime.onTabClosed = { tab in
      if self.expectedRegularRouteIDs.contains(tab) { self.regularCallbackContamination = true }
      self.previousTabClosed?(tab)
    }
  }

  private func restorePrivateCallbackAudit() {
    runtime.onTabChanged = previousTabChanged
    runtime.onTabClosed = previousTabClosed
    runtime.onPrivateTabChanged = previousPrivateTabChanged
    runtime.onPrivateTabSelected = previousPrivateTabSelected
    runtime.onPrivateTabClosed = previousPrivateTabClosed
    runtime.onPrivateWindowClosed = previousPrivateWindowClosed
  }

  private func closeTab(_ tab: String, window: String, context: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.closePrivateTabID(tab, windowID: window, contextID: context) {
        continuation.resume(returning: $0)
      }
    }
  }

  private func exerciseNavigation(tab: String, window: String, context: String, marker: String)
    async throws -> Bool
  {
    let first = fixture.appending(path: "private-window-\(marker)-nav-a")
    let second = fixture.appending(path: "private-window-\(marker)-nav-b")
    guard
      runtime.navigatePrivateTabID(
        tab, windowID: window, contextID: context, url: first.absoluteString),
      try await waitForPrivatePath(tab, firstPath: first.path)
    else { return false }
    guard
      runtime.navigatePrivateTabID(
        tab, windowID: window, contextID: context, url: second.absoluteString),
      try await waitForPrivatePath(tab, firstPath: second.path)
    else { return false }
    guard let priorInstance = try await readPrivate(tab)["instance"] as? String,
      UUID(uuidString: priorInstance) != nil
    else { return false }
    guard runtime.reloadPrivateTabID(tab, windowID: window, contextID: context) else {
      return false
    }
    guard
      try await waitForPrivateReload(
        tab, path: second.path, priorInstance: priorInstance)
    else { return false }
    guard runtime.goBackPrivateTabID(tab, windowID: window, contextID: context),
      try await waitForPrivatePath(tab, firstPath: first.path)
    else { return false }
    guard runtime.goForwardPrivateTabID(tab, windowID: window, contextID: context),
      try await waitForPrivatePath(tab, firstPath: second.path)
    else { return false }
    return true
  }

  private func waitForPrivatePath(_ tab: String, firstPath path: String) async throws -> Bool {
    for _ in 0..<100 {
      if let value = try? await readPrivate(tab), value["path"] as? String == path {
        return true
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func waitForPrivateReload(_ tab: String, path: String, priorInstance: String)
    async throws -> Bool
  {
    for _ in 0..<100 {
      if let value = try? await readPrivate(tab),
        value["fixture"] as? String == "v1",
        value["path"] as? String == path,
        let instance = value["instance"] as? String,
        UUID(uuidString: instance) != nil,
        instance != priorInstance
      {
        return true
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func evaluateNormal(_ tab: String, _ script: String) async throws -> [String: Any] {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluate(inTabID: tab, script: script) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8),
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw PrivateWindowFailure("Normal fixture evaluation failed.")
    }
    return value
  }

  private func readPrivate(_ tab: String) async throws -> [String: Any] {
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivateProbeTabID(
        tab,
        script:
          "({fixture:document.documentElement.dataset.arcusisFixture, cookie:document.cookie, local:localStorage.getItem('private'), session:sessionStorage.getItem('private'), path:location.pathname, instance:window.arcusisInstance})"
      ) { continuation.resume(returning: $0) }
    }
    guard let json, let data = json.data(using: .utf8) else {
      privateEvaluationShape = "missing-json"
      lastDocumentAudit["privateEvaluationShape"] = privateEvaluationShape
      throw PrivateWindowFailure("Private fixture evaluation failed or used stale context.")
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    guard let value = object as? [String: Any] else {
      privateEvaluationShape = "json-type:" + String(describing: type(of: object))
      lastDocumentAudit["privateEvaluationShape"] = privateEvaluationShape
      throw PrivateWindowFailure("Private fixture evaluation failed or used stale context.")
    }
    privateEvaluationShape = "object:" + value.keys.sorted().joined(separator: ",")
    return value
  }

  private func setPrivate(_ tab: String, cookie: String, storage: String, session: String)
    async throws
  {
    let literal = try JSONEncoder().encode(storage)
    guard let value = String(data: literal, encoding: .utf8) else {
      throw PrivateWindowFailure("Marker encoding failed.")
    }
    let json: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivateProbeTabID(
        tab,
        script:
          "(()=>{document.cookie='private=\(cookie); Path=/; SameSite=Lax';localStorage.setItem('private',\(value));sessionStorage.setItem('private',\(value));return true})()"
      ) { continuation.resume(returning: $0) }
    }
    guard json != nil else {
      throw PrivateWindowFailure("Could not author private storage markers.")
    }
  }

  private func waitForFixture(tabID: String, privateTab: Bool, contextID: String? = nil)
    async throws
  {
    if privateTab { stage = "private-document-load" }
    for _ in 0..<100 {
      do {
        if privateTab {
          let audit = runtime.privateProbeAudit(forContextID: contextID ?? "") ?? [:]
          lastDocumentAudit = [
            "contextIsPrivate": audit["contextIsPrivate"] as? Bool == true,
            "profileAlive": audit["profileAlive"] as? Bool == true,
            "allTabsLoaded": audit["allTabsLoaded"] as? Bool == true,
            "allTabsAuthoredLoopbackURL": audit["allTabsAuthoredLoopbackURL"] as? Bool == true,
            "anyTabLoading": audit["anyTabLoading"] as? Bool == true,
            "allWindowsHidden": audit["allWindowsHidden"] as? Bool == true,
            "allTabsInNativeProfileBrowser":
              audit["allTabsInNativeProfileBrowser"] as? Bool == true,
            "allTabsAttachedToHostView":
              audit["allTabsAttachedToHostView"] as? Bool == true,
            "allWindowsUsePrivateActiveProfile":
              audit["allWindowsUsePrivateActiveProfile"] as? Bool == true,
            "allWindowsDisplayOwnedWebContents":
              audit["allWindowsDisplayOwnedWebContents"] as? Bool == true,
            "tabCount": audit["tabCount"] ?? 0,
            "windowCount": audit["windowCount"] ?? 0,
            "privateEvaluationRejected": audit["privateEvaluationRejected"] as? Bool == true,
            "privateEvaluationStale": audit["privateEvaluationStale"] as? Bool == true,
            "privateEvaluationSucceeded": audit["privateEvaluationSucceeded"] as? Bool == true,
            "privateEvaluationTimedOut": audit["privateEvaluationTimedOut"] as? Bool == true,
          ]
          if lastDocumentAudit["allTabsLoaded"] as? Bool != true {
            try await Task.sleep(for: .milliseconds(100))
            continue
          }
        }
        let fixtureLoaded: Bool
        if privateTab {
          lastDocumentAudit["fixtureLoaded"] = false
          lastDocumentAudit["privateEvaluationResponded"] = false
          fixtureLoaded =
            try await readPrivate(tabID)["fixture"] as? String == "v1"
          lastDocumentAudit["fixtureLoaded"] = fixtureLoaded
          lastDocumentAudit["privateEvaluationResponded"] = true
        } else {
          let value = try await evaluateNormal(
            tabID, "({fixture:document.documentElement.dataset.arcusisFixture})")
          fixtureLoaded = value["fixture"] as? String == "v1"
        }
        if fixtureLoaded {
          if privateTab { stage = "private-document-ready" }
          return
        }
      } catch {}
      try await Task.sleep(for: .milliseconds(100))
    }
    throw PrivateWindowFailure("Authored loopback document did not become ready.")
  }

  private func authorNormalHistory(path: String) async throws {
    var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)
    components?.path = path
    guard let url = components?.url?.absoluteString else {
      throw PrivateWindowFailure("Could not form authored normal history URL.")
    }
    let tabID = UUID().uuidString.uppercased()
    try runtime.openTabID(
      tabID, profileID: sourceA, windowID: runtime.primaryWindowID, url: "about:blank")
    guard
      runtime.navigateTabID(
        tabID, profileID: sourceA, windowID: runtime.primaryWindowID, url: url)
    else { throw PrivateWindowFailure("Could not author a real normal native history visit.") }
    try await waitForFixture(tabID: tabID, privateTab: false)
    runtime.closeTabID(tabID)
    for _ in 0..<100 {
      if runtime.nativeTabID(forID: tabID) < 0 {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Authored normal history tab did not close.")
  }

  private func waitUntil(_ tab: String, predicate: ([String: Any]) -> Bool) async throws {
    for _ in 0..<100 {
      if let value = try? await readPrivate(tab), predicate(value) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw PrivateWindowFailure("Shared OTR state did not reach second private tab.")
  }

  private func history(_ profile: String, contains path: String) async throws -> Bool {
    for _ in 0..<40 {
      let found: Bool = await withCheckedContinuation { continuation in
        runtime.history(forProfileID: profile, limit: 500) { rows, error in
          let paths = Self.historyPaths(rows)
          self.historyEntryCount = paths.count
          self.historyQuerySucceeded = error == nil && rows?.isEmpty == false
          self.historyPathDigest = Digest.sha256(Data(paths.sorted().joined(separator: "\n").utf8))
          continuation.resume(
            returning: rows?.contains {
              ($0["u"] as? String).map { URL(string: $0)?.path == path } == true
            } ?? false)
        }
      }
      if found { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private func history(_ profile: String, excludes component: String, retaining normalPath: String)
    async throws -> Bool
  {
    for _ in 0..<40 {
      let retainedAndExcluded: Bool = await withCheckedContinuation { continuation in
        runtime.history(forProfileID: profile, limit: 500) { rows, error in
          let paths = Self.historyPaths(rows)
          self.historyEntryCount = rows?.count ?? 0
          self.historyQuerySucceeded = error == nil && rows?.isEmpty == false
          self.historyPathDigest = Digest.sha256(Data(paths.sorted().joined(separator: "\n").utf8))
          let hasNormalControl =
            rows?.contains {
              ($0["u"] as? String).map { URL(string: $0)?.path == normalPath } == true
            } == true
          let hasPrivateVisit =
            rows?.contains {
              ($0["u"] as? String)?.contains(component) == true
            } == true
          continuation.resume(returning: error == nil && hasNormalControl && !hasPrivateVisit)
        }
      }
      if retainedAndExcluded { return true }
      try await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  private static func historyPaths(_ rows: [[AnyHashable: Any]]?) -> [String] {
    rows?.compactMap { row in
      guard let value = row["u"] as? String else { return nil }
      return URL(string: value)?.path
    } ?? []
  }

  private func normalSelectionRetained() -> Bool {
    let after = runtime.normalProbeSelectionAudit(forTabID: normalTab)
    let beforeSelected = normalSelectionBefore["selectedNativeTab"] as? Bool == true
    let beforeDisplayed = normalSelectionBefore["displayedNativeWebContents"] as? Bool == true
    let beforeAttached = normalSelectionBefore["selectedViewAttached"] as? Bool == true
    let beforeVisible = normalSelectionBefore["selectedViewVisible"] as? Bool == true
    let afterSelected = after["selectedNativeTab"] as? Bool == true
    let afterDisplayed = after["displayedNativeWebContents"] as? Bool == true
    let afterAttached = after["selectedViewAttached"] as? Bool == true
    let afterVisible = after["selectedViewVisible"] as? Bool == true
    let sameNativeTab =
      normalSelectionBefore["nativeTabToken"] as? String == after["nativeTabToken"] as? String
    normalSelectionAudit = [
      "beforeSelectedNativeTab": beforeSelected,
      "beforeDisplayedNativeWebContents": beforeDisplayed,
      "beforeSelectedViewAttached": beforeAttached,
      "beforeSelectedViewVisible": beforeVisible,
      "beforePrimaryWindow": normalSelectionBefore["primaryWindow"] as? Bool == true,
      "beforeSelectedID": normalSelectionBefore["selectedID"] as? Bool == true,
      "beforeActiveProfile": normalSelectionBefore["activeProfile"] as? Bool == true,
      "beforeLiveTab": normalSelectionBefore["liveTab"] as? Bool == true,
      "beforeNativeProfileOwnsTab": normalSelectionBefore["nativeProfileOwnsTab"] as? Bool == true,
      "beforeVisibleNativeViewCount": normalSelectionBefore["visibleNativeViewCount"] ?? -1,
      "afterSelectedNativeTab": afterSelected,
      "afterDisplayedNativeWebContents": afterDisplayed,
      "afterSelectedViewAttached": afterAttached,
      "afterSelectedViewVisible": afterVisible,
      "afterPrimaryWindow": after["primaryWindow"] as? Bool == true,
      "afterSelectedID": after["selectedID"] as? Bool == true,
      "afterActiveProfile": after["activeProfile"] as? Bool == true,
      "afterLiveTab": after["liveTab"] as? Bool == true,
      "afterNativeProfileOwnsTab": after["nativeProfileOwnsTab"] as? Bool == true,
      "afterVisibleNativeViewCount": after["visibleNativeViewCount"] ?? -1,
      "sameNativeTabObject": sameNativeTab,
    ]
    return beforeSelected && beforeDisplayed && beforeVisible && afterSelected && afterDisplayed
      && afterVisible && sameNativeTab
  }

  private func writeReport(runID: String) throws {
    let sanitized = Dictionary(uniqueKeysWithValues: checks.map { ($0.key, $0.value) })
    let retirementAudit = privateContexts.compactMap { contextID -> [String: Any]? in
      guard let audit = runtime.privateProbeAudit(forContextID: contextID) else { return nil }
      return [
        "windowCount": audit["windowCount"] ?? -1,
        "pendingWindowCount": audit["pendingWindowCount"] ?? -1,
        "profileAlive": audit["profileAlive"] ?? false,
        "sourceLeaseOwnsContext": audit["sourceLeaseOwnsContext"] ?? false,
        "noPendingFactory": audit["noPendingFactory"] ?? false,
      ]
    }
    let report: [String: Any] = [
      "schema": 1, "mode": Self.mode, "phase": phase, "runID": runID,
      "passed": Self.checkNames.allSatisfy { checks[$0] == true },
      "checkCount": checks.count, "requiredCheckCount": Self.checkNames.count,
      "checks": sanitized,
      "lastStage": stage,
      "pendingCallbackExercise":
        "Two same-source contexts queued before pinned native factory callback; each waiter retires its context reentrantly.",
      "lastDocumentAudit": lastDocumentAudit.merging(
        ["privateEvaluationShape": privateEvaluationShape], uniquingKeysWith: { _, value in value }),
      "normalSelectionAudit": normalSelectionAudit,
      "retirementAudit": retirementAudit,
      "historyPathDigest": historyPathDigest ?? Digest.sha256(Data("missing-history".utf8)),
      "historyEntryCount": historyEntryCount,
      "historyQuerySucceeded": historyQuerySucceeded,
      "workspaceSHA256": productWorkspaceSHA256 ?? "",
      "productScreenshotSHA256": productScreenshotSHA256 ?? "",
      "productRendererScreenshotSHA256": productRendererScreenshotSHA256 ?? "",
      "productRendererViewportAudit": productRendererViewportAudit,
      "productRendererCaptureOutcome": productRendererCaptureOutcome,
      "productLifecycleBlocker": productLifecycleBlocker ?? "",
      "cleanup": [
        "windowsRemaining": privateWindows.count, "contextsRemaining": privateContexts.count,
        "passed": privateWindows.isEmpty && privateContexts.isEmpty
          && productLifecycleBlocker == "",
      ],
      "scope":
        "Owned hidden native product and engine windows on synthetic loopback origin. No real accounts, vendor endpoints, physical input, or company acceptance tested.",
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appending(path: "\(phase)-private-window.json"), options: .atomic)
  }
}

private enum Digest {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct PrivateWindowFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
