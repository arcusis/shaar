import AppKit
import BrowserCore
import ChromiumBridge
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class PrivateProductHostProbe {
  struct Evidence {
    let checks: [String: Bool]
    let workspaceSHA256: String
    let screenshotSHA256: String
    let rendererScreenshotSHA256: String
    let rendererViewportAudit: [String: Any]
    let rendererCaptureOutcome: String
    let lifecycleBlocker: String
  }

  private struct NativeCloseObservation {
    let contextID: String
    let confirmedWhileQuitting: Bool
  }

  private struct NativeCloseReceipt {
    let closed: Bool
    let requestedWhileQuitting: Bool
    let confirmedWhileQuitting: Bool
  }

  private let runtime: ARCChromiumRuntime
  private let root: URL
  private let fixture: URL
  private let phase: String
  private let runID: String
  private let normalSession: BrowserSession
  private let sourceA: String
  private let sourceB: String
  private var source: String
  private var keyWindow: NSWindow?
  private var host: PrivateBrowserHost?
  private var checks: [String: Bool] = [:]
  private var workspaceBytes = Data()
  private var screenshotDigest = ""
  private var rendererScreenshotDigest = ""
  private var rendererViewportAudit: [String: Any] = [:]
  private var rendererCaptureOutcome = "not-attempted"
  private var lifecycleBlocker = ""
  private var quitDiagnosticStages: [[String: Any]] = []
  private var nativeCloseObservations: [String: NativeCloseObservation] = [:]
  private weak var lifecycleStore: PrivateBrowserStore?
  private weak var lifecycleHosting: NSHostingView<PrivateBrowserWindow>?

  init(
    runtime: ARCChromiumRuntime, root: URL, fixture: URL, phase: String,
    runID: String, normalSession: BrowserSession, sourceA: String, sourceB: String
  ) {
    self.runtime = runtime
    self.root = root
    self.fixture = fixture
    self.phase = phase
    self.runID = runID
    self.normalSession = normalSession
    self.sourceA = sourceA
    self.sourceB = sourceB
    source = sourceA
  }

  func run() async throws -> Evidence {
    let workspaceURL = root.appending(path: "workspace.json")
    let workspace = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: workspaceURL, legacySessionURL: root.appending(path: "unused-legacy-session.json")),
      initialSession: normalSession)
    guard !workspace.workspace.windows.isEmpty,
      let before = try? Data(contentsOf: workspaceURL), !before.isEmpty
    else {
      throw PrivateWindowFailure("Product host could not snapshot normal workspace bytes.")
    }
    workspaceBytes = before
    let privateHost = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      keyWindow: { [weak self] in self?.keyWindow },
      sourceProfileID: { [weak self] in self?.source })
    host = privateHost
    privateHost.installCallbacks()
    // Record native confirmation before the product retires its last context.
    let forwardNativeClose = runtime.onPrivateWindowClosed
    runtime.onPrivateWindowClosed = { [weak self] contextID, windowID in
      if let self {
        self.nativeCloseObservations[windowID] = NativeCloseObservation(
          contextID: contextID, confirmedWhileQuitting: self.runtime.isQuitting)
      }
      forwardNativeClose?(contextID, windowID)
    }
    do {
      try await exercise(privateHost)
      if privateHost.windowCount == 0 {
        privateHost.detach()
        try await waitForOwnerDeallocation()
      } else if lifecycleBlocker.isEmpty {
        lifecycleBlocker = "Confirmed native close missing; private owner remains live."
      }
      guard let after = try? Data(contentsOf: workspaceURL), after == workspaceBytes else {
        throw PrivateWindowFailure("Private product operations changed normal workspace bytes.")
      }
      checks["productWeakStoreReleasedAfterConfirmedClose"] = lifecycleStore == nil
      checks["productWeakHostingReleasedAfterConfirmedClose"] = lifecycleHosting == nil
      return Evidence(
        checks: checks, workspaceSHA256: sha256(after), screenshotSHA256: screenshotDigest,
        rendererScreenshotSHA256: rendererScreenshotDigest,
        rendererViewportAudit: rendererViewportAudit,
        rendererCaptureOutcome: rendererCaptureOutcome,
        lifecycleBlocker: lifecycleBlocker)
    } catch {
      if let tabID = normalSession.selectedSpace.selectedTabID?.uuidString {
        _ = await removeBeforeUnload(on: tabID)
      }
      if privateHost.windowCount == 0 {
        privateHost.detach()
      } else {
        lifecycleBlocker = error.localizedDescription
      }
      throw error
    }
  }

  private func exercise(_ privateHost: PrivateBrowserHost) async throws {
    try privateHost.openWindow()
    try await waitForWindows(privateHost, count: 1)
    try await exerciseFirstWindow(privateHost)

    let normalHistoryExcludesProductVisit = await historyExcludesProductVisit()
    checks["productNormalHistoryExcludesPrivateVisit"] = normalHistoryExcludesProductVisit
    guard let after = try? Data(contentsOf: root.appending(path: "workspace.json")) else {
      throw PrivateWindowFailure("Normal workspace disappeared during private operations.")
    }
    checks["productWorkspaceBytesUnchanged"] = after == workspaceBytes

    let contextIDs = Set(privateHost.ownedWindows.map(\.contextID))
    for owner in privateHost.ownedWindows {
      _ = await withCheckedContinuation { continuation in
        runtime.closePrivateWindowID(owner.windowID, contextID: owner.contextID) { closed in
          continuation.resume(returning: closed)
        }
      }
    }
    try await waitForWindows(privateHost, count: 0)
    checks["productFinalCloseReleasesOwners"] =
      privateHost.windowCount == 0
      && privateHost.ownedWindows.isEmpty
      && contextIDs.allSatisfy { runtime.privateProbeAudit(forContextID: $0) == nil }
    guard let final = try? Data(contentsOf: root.appending(path: "workspace.json")) else {
      throw PrivateWindowFailure("Normal workspace disappeared after private close.")
    }
    checks["productWorkspaceBytesUnchangedAfterClose"] = final == workspaceBytes

    source = sourceA
    try privateHost.openWindow()
    try await waitForWindows(privateHost, count: 1)
    guard let quitOwner = privateHost.ownedWindows.first else {
      throw PrivateWindowFailure("Private quit fixture did not retain its owner.")
    }
    let liveContext = quitOwner.contextID
    guard let normalTabID = normalSession.selectedSpace.selectedTabID?.uuidString,
      let normalWindow = runtime.window(forID: runtime.primaryWindowID)
    else {
      throw PrivateWindowFailure("Normal fixture page was missing before native quit test.")
    }
    let beforeUnloadActivated = await installBeforeUnloadWithUserActivation(on: normalTabID)
    let beforeUnloadHandlerInstalled = await hasBeforeUnloadHandler(on: normalTabID)
    checks["productBeforeUnloadUsesRendererUserActivation"] = beforeUnloadActivated
    writeQuitDiagnostic(
      "beforeFirstNativeQuit", owner: quitOwner, normalWindow: normalWindow,
      normalTabID: normalTabID,
      values: [
        "beforeUnloadActivated": beforeUnloadActivated,
        "beforeUnloadHandlerInstalled": beforeUnloadHandlerInstalled,
      ])
    guard beforeUnloadActivated, await prepareNativeQuitCancellation(on: normalTabID) else {
      throw PrivateWindowFailure(
        "Normal fixture page could not arm beforeunload with renderer user activation.")
    }
    let firstHoldAudit = runtime.privateQuitCDPHoldAudit(forTabID: normalTabID) ?? [:]
    let firstHoldConfirmed =
      firstHoldAudit["holdCommandPending"] as? Bool == true
      && firstHoldAudit["holdConfirmedPending"] as? Bool == true
      && firstHoldAudit["selectedNormalTab"] as? Bool == true
    checks["productNativeCDPHoldConfirmedPending"] = firstHoldConfirmed
    writeQuitDiagnostic(
      "nativeCDPHoldConfirmedPending", owner: quitOwner, normalWindow: normalWindow,
      normalTabID: normalTabID,
      values: [
        "cdpHoldCommandPending": firstHoldAudit["holdCommandPending"] ?? false,
        "cdpHoldConfirmedPending": firstHoldAudit["holdConfirmedPending"] ?? false,
        "cdpHoldSelectedNormalTab": firstHoldAudit["selectedNormalTab"] ?? false,
      ])
    guard firstHoldConfirmed else {
      throw PrivateWindowFailure("Normal fixture CDP ownership hold was not confirmed pending.")
    }
    let firstQuitTask = Task { @MainActor in
      self.writeQuitDiagnostic(
        "nativeQuitRequested", owner: quitOwner, normalWindow: normalWindow,
        normalTabID: normalTabID)
      return await self.cancelQuitThroughNativeBeforeUnload(
        host: privateHost, owner: quitOwner, normalWindow: normalWindow,
        normalTabID: normalTabID, closePrivateWindow: false)
    }
    Task { @MainActor in runtime.quit() }
    let firstCancellation = await firstQuitTask.value
    let handlerFired = await beforeUnloadHandlerFired(on: normalTabID)
    checks["productNativeBeforeUnloadHandlerFired"] = handlerFired
    writeQuitDiagnostic(
      "firstCancellationReturned", owner: quitOwner, normalWindow: normalWindow,
      normalTabID: normalTabID,
      values: [
        "nativeCancellationReturned": firstCancellation,
        "beforeUnloadHandlerFired": handlerFired,
      ])
    let normalSelection = runtime.normalProbeSelectionAudit(forTabID: normalTabID)
    let normalStillSelected =
      normalSelection["selectedNativeTab"] as? Bool == true
      && normalSelection["displayedNativeWebContents"] as? Bool == true
    let liveOwnerRetained = privateHost.ownedWindows.contains {
      $0.windowID == quitOwner.windowID && $0.contextID == liveContext
    }
    let liveContextRetained = runtime.privateProbeAudit(forContextID: liveContext) != nil
    let cancelledQuitRestored = !runtime.isQuitting
    let normalWindowSurvived =
      runtime.window(forID: runtime.primaryWindowID) != nil
      && normalStillSelected
    checks["productNativeQuitCancellationReturned"] = firstCancellation
    checks["productCancelledQuitRestoredRuntimeState"] = cancelledQuitRestored
    checks["productCancelledQuitRetainedPrivateWindow"] = liveOwnerRetained
    checks["productCancelledQuitRetainedPrivateContext"] = liveContextRetained
    checks["productCancelledQuitRetainedNormalWindow"] = normalWindowSurvived
    checks["productCancelledQuitRetainsLivePrivateLease"] =
      firstCancellation && cancelledQuitRestored && liveOwnerRetained
      && liveContextRetained && normalWindowSurvived
    if checks["productCancelledQuitRetainsLivePrivateLease"] != true {
      lifecycleBlocker =
        "Native canceled quit evidence: cancellation=\(firstCancellation), runtimeRestored=\(cancelledQuitRestored), privateWindowRetained=\(liveOwnerRetained), privateContextRetained=\(liveContextRetained), normalWindowSurvived=\(normalWindowSurvived)."
      checks["productFinalCloseAfterCancelledQuitReleasesLease"] = false
      checks["productCancelledQuitRetiresOnlyConfirmedPrivateLease"] = false
      checks["productBeforeUnloadRemovedBeforeFinalFixtureQuit"] =
        await removeBeforeUnload(on: normalTabID)
      if let after = try? Data(contentsOf: root.appending(path: "workspace.json")) {
        checks["productWorkspaceBytesUnchangedAfterClose"] = after == workspaceBytes
      } else {
        checks["productWorkspaceBytesUnchangedAfterClose"] = false
      }
      return
    }
    let firstClose = await closeNativeWindow(quitOwner)
    checks["productFinalCloseAfterCancelledQuitReleasesLease"] =
      firstClose
      && privateHost.windowCount == 0 && runtime.privateProbeAudit(forContextID: liveContext) == nil

    try privateHost.openWindow()
    try await waitForWindows(privateHost, count: 1)
    guard let finalQuitOwner = privateHost.ownedWindows.first else {
      throw PrivateWindowFailure("Private final-quit fixture did not retain its owner.")
    }
    let finalQuitContext = finalQuitOwner.contextID
    guard await prepareNativeQuitCancellation(on: normalTabID) else {
      throw PrivateWindowFailure("Normal fixture page could not rearm native quit cancellation.")
    }
    let finalHoldAudit = runtime.privateQuitCDPHoldAudit(forTabID: normalTabID) ?? [:]
    let finalHoldConfirmed =
      finalHoldAudit["holdCommandPending"] as? Bool == true
      && finalHoldAudit["holdConfirmedPending"] as? Bool == true
      && finalHoldAudit["selectedNormalTab"] as? Bool == true
    checks["productNativeCDPHoldConfirmedPending"] =
      checks["productNativeCDPHoldConfirmedPending"] == true && finalHoldConfirmed
    guard finalHoldConfirmed else {
      throw PrivateWindowFailure(
        "Final normal fixture CDP ownership hold was not confirmed pending.")
    }
    writeQuitDiagnostic(
      "beforeFinalCloseNativeQuit", owner: finalQuitOwner, normalWindow: normalWindow,
      normalTabID: normalTabID)
    let finalCloseQuitTask = Task { @MainActor in
      self.writeQuitDiagnostic(
        "finalCloseNativeQuitRequested", owner: finalQuitOwner, normalWindow: normalWindow,
        normalTabID: normalTabID)
      return await self.cancelQuitThroughNativeBeforeUnload(
        host: privateHost, owner: finalQuitOwner, normalWindow: normalWindow,
        normalTabID: normalTabID, closePrivateWindow: true)
    }
    Task { @MainActor in runtime.quit() }
    let finalCloseQuitCancelled = await finalCloseQuitTask.value
    let finalPrivateWindowClosed =
      finalCloseQuitCancelled
      && privateHost.windowCount == 0
      && runtime.privateProbeAudit(forContextID: finalQuitContext) == nil
    checks["productFinalPrivateWindowCloseRequestedWhileQuitAndReleasedAfterConfirmation"] =
      finalCloseQuitCancelled && finalPrivateWindowClosed
    writeQuitDiagnostic(
      "finalCloseCancellationReturned", owner: finalQuitOwner,
      normalWindow: normalWindow, normalTabID: normalTabID,
      values: [
        "nativeCancellationReturned": finalCloseQuitCancelled,
        "nativePrivateWindowCloseReturned": finalPrivateWindowClosed,
      ])
    let finalNormalSelection = runtime.normalProbeSelectionAudit(forTabID: normalTabID)
    let finalNormalStillSelected =
      finalNormalSelection["selectedNativeTab"] as? Bool == true
      && finalNormalSelection["displayedNativeWebContents"] as? Bool == true
    checks["productCancelledQuitRetiresOnlyConfirmedPrivateLease"] =
      finalCloseQuitCancelled && finalPrivateWindowClosed && !runtime.isQuitting
      && privateHost.windowCount == 0
      && runtime.privateProbeAudit(forContextID: finalQuitContext) == nil
      && runtime.window(forID: runtime.primaryWindowID) != nil && finalNormalStillSelected
    checks["productBeforeUnloadRemovedBeforeFinalFixtureQuit"] =
      await removeBeforeUnload(on: normalTabID)
    guard let postQuitWorkspace = try? Data(contentsOf: root.appending(path: "workspace.json"))
    else {
      throw PrivateWindowFailure("Normal workspace disappeared after canceled app quit.")
    }
    checks["productWorkspaceBytesUnchangedAfterClose"] = postQuitWorkspace == workspaceBytes

  }

  private func exerciseFirstWindow(_ privateHost: PrivateBrowserHost) async throws {
    guard let first = privateHost.ownedWindows.first else {
      throw PrivateWindowFailure("Private product host did not retain first native owner.")
    }
    lifecycleStore = first.store
    lifecycleHosting = first.hosting
    keyWindow = first.window
    let nativePageView = runtime.view(
      forPrivateTabID: first.store.selectedTabID,
      windowID: first.windowID, contextID: first.contextID)
    checks["productHostOwnsPrivateNativeWindow"] =
      first.store.windowID == first.windowID
      && first.store.contextID == first.contextID
      && first.hosting.rootView.store === first.store
      && first.hosting.superview
        === runtime.hostView(
          forPrivateWindowID:
            first.windowID, contextID: first.contextID)
      && nativePageView.map { isDescendant($0, of: first.hosting) } == true

    let firstPath = fixture.appending(path: "private-product-\(runID.lowercased())-a")
      .absoluteString
    first.store.openTab()
    try await waitForTabs(first.store, count: 2)
    guard let secondTab = first.store.selectedTab else {
      throw PrivateWindowFailure("Private Command-T did not select transient tab.")
    }
    checks["productPrivateFocusUsesOwnedTab"] = runtime.focusPrivateTabID(
      secondTab.id, windowID: first.windowID, contextID: first.contextID)
    let firstTabID = first.store.tabs.first(where: { $0.id != secondTab.id })?.id
    if let firstTabID {
      first.store.selectTab(firstTabID)
      first.store.selectTab(secondTab.id)
    }
    first.store.navigate(firstPath)
    try await waitForURL(first.store, tabID: secondTab.id, contains: "private-product-")
    let nextPath = fixture.appending(path: "private-product-\(runID.lowercased())-next")
      .absoluteString
    first.store.navigate(nextPath)
    try await waitForURL(first.store, tabID: secondTab.id, contains: "-next")
    try await waitForTab(first.store, tabID: secondTab.id, canGoBack: true)
    first.store.goBack()
    try await waitForURL(first.store, tabID: secondTab.id, contains: "private-product-")
    first.store.goForward()
    try await waitForURL(first.store, tabID: secondTab.id, contains: "-next")
    first.store.reload()
    try await waitForLoading(first.store, tabID: secondTab.id, loading: true)
    try await waitForLoading(first.store, tabID: secondTab.id, loading: false)
    checks["productPrivateNavigationReloadBackForwardCallbacks"] =
      firstTabID != nil && first.store.selectedTabID == secondTab.id
      && first.store.tabs.first(where: { $0.id == secondTab.id })?.url.contains("-next") == true
    privateHost.perform(.newTab)
    try await waitForTabs(first.store, count: 3)
    guard let commandTab = first.store.selectedTab else {
      throw PrivateWindowFailure("Private Command-T did not create a selected native tab.")
    }
    checks["productCommandTUsesPrivateOpaqueSearch"] =
      privateHost.activeOwner?.windowID == first.windowID
      && privateHost.canPerform(.newTab)
      && first.store.commandIsOpen && first.store.tabs.count == 3
      && commandTab.id != secondTab.id
    privateHost.perform(.search)
    checks["productCommandLTargetsCurrentPrivateTab"] =
      first.store.tabs.count == 3
      && first.store.selectedTabID == commandTab.id && first.store.commandIsOpen
    first.store.commandQuery =
      fixture.appending(
        path: "private-product-\(runID.lowercased())-command-t"
      ).absoluteString
    first.store.submitCommand()
    try await waitForURL(first.store, tabID: commandTab.id, contains: "-command-t")
    first.store.showCommand()
    let captures = try await capturePrivateWindow(first, runID: runID, phase: phase)
    screenshotDigest = captures.hostDigest
    rendererScreenshotDigest = captures.rendererDigest
    first.store.commandIsOpen = false

    try privateHost.openWindow()
    try await waitForWindows(privateHost, count: 2)
    let sameSource = privateHost.ownedWindows.first { $0.windowID != first.windowID }
    checks["productSameSourceWindowsShareContext"] =
      sameSource?.contextID == first.contextID
      && sameSource?.sourceProfileID == sourceA

    source = sourceB
    try privateHost.openWindow()
    try await waitForWindows(privateHost, count: 3)
    let differentSource = privateHost.ownedWindows.first { $0.sourceProfileID == sourceB }
    checks["productDifferentSourceWindowsIsolateContext"] =
      differentSource != nil
      && differentSource?.contextID != first.contextID

    let cancelled = runtime.attemptCancelledPrivateProbeCloseID(first.windowID)
    checks["productCancelledCloseRetainsOwner"] =
      cancelled
      && privateHost.ownedWindows.contains { $0.windowID == first.windowID }
      && first.store.tabs.count == 3
      && lifecycleStore === first.store && lifecycleHosting === first.hosting
  }

  private func isDescendant(_ view: NSView, of parent: NSView) -> Bool {
    var current: NSView? = view
    while let view = current {
      if view === parent { return true }
      current = view.superview
    }
    return false
  }

  private func waitForTab(
    _ store: PrivateBrowserStore, tabID: String, canGoBack: Bool
  ) async throws {
    for _ in 0..<100 {
      if store.tabs.first(where: { $0.id == tabID })?.canGoBack == canGoBack { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product navigation state callback timed out.")
  }

  private func waitForLoading(
    _ store: PrivateBrowserStore, tabID: String, loading: Bool
  ) async throws {
    for _ in 0..<100 {
      if store.tabs.first(where: { $0.id == tabID })?.loading == loading { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product loading callback timed out.")
  }

  private func historyExcludesProductVisit() async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.history(forProfileID: sourceA, limit: 500) { rows, error in
        let hasProductVisit =
          rows?.contains {
            ($0["u"] as? String)?.contains("private-product-\(self.runID.lowercased())") == true
          } == true
        continuation.resume(returning: error == nil && rows?.isEmpty == false && !hasProductVisit)
      }
    }
  }

  private func waitForWindows(_ privateHost: PrivateBrowserHost, count: Int) async throws {
    for _ in 0..<100 {
      if privateHost.windowCount == count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product native window ownership timed out.")
  }

  private func waitForOwnerDeallocation() async throws {
    for _ in 0..<100 {
      if lifecycleStore == nil && lifecycleHosting == nil { return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func waitForQuitCancellation(_ cancelled: () -> Bool) async throws {
    for _ in 0..<100 {
      if cancelled() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Owned engine quit did not return through native cancellation.")
  }

  private func installBeforeUnloadWithUserActivation(on tabID: String) async -> Bool {
    let prepared: Bool = await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tabID,
        script: """
          (()=>{
            const id='arcusis-private-quit-activation';
            document.getElementById(id)?.remove();
            const button=document.createElement('button');
            button.id=id;
            button.textContent='Activate owned quit fixture';
            button.style.cssText='position:fixed;left:8px;top:8px;z-index:2147483647;width:180px;height:32px';
            button.addEventListener('click',event=>{window.__arcusisQuitClickTrusted=event.isTrusted;});
            document.body.appendChild(button);
            return true;
          })()
          """
      ) { result in
        continuation.resume(returning: result == "true")
      }
    }
    guard prepared else { return false }
    let clicked: Bool = await withCheckedContinuation { continuation in
      runtime.clickProbeElement(inTabID: tabID, elementID: "arcusis-private-quit-activation") {
        continuation.resume(returning: $0)
      }
    }
    guard clicked else { return false }
    return await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tabID,
        script: """
          (()=>{
            if(!navigator.userActivation.hasBeenActive||window.__arcusisQuitClickTrusted!==true)return false;
            document.getElementById('arcusis-private-quit-activation')?.remove();
            window.__arcusisBeforeUnloadInstalled=true;
            window.__arcusisBeforeUnload=event=>{window.__arcusisBeforeUnloadFired=true;event.preventDefault();event.returnValue='';};
            addEventListener('beforeunload',window.__arcusisBeforeUnload);
            return true;
          })()
          """
      ) { result in
        continuation.resume(returning: result == "true")
      }
    }
  }

  private func removeBeforeUnload(on tabID: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tabID,
        script:
          "(()=>{if(window.__arcusisBeforeUnload)removeEventListener('beforeunload',window.__arcusisBeforeUnload);delete window.__arcusisBeforeUnload;return true;})()"
      ) { result in
        continuation.resume(returning: result == "true")
      }
    }
  }

  private func hasBeforeUnloadHandler(on tabID: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tabID,
        script:
          "typeof window.__arcusisBeforeUnload==='function'&&window.__arcusisBeforeUnloadInstalled===true"
      ) { result in
        continuation.resume(returning: result == "true")
      }
    }
  }

  private func beforeUnloadHandlerFired(on tabID: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.evaluate(
        inTabID: tabID, script: "window.__arcusisBeforeUnloadFired===true"
      ) { result in
        continuation.resume(returning: result == "true")
      }
    }
  }

  private func writeQuitDiagnostic(
    _ stage: String, owner: PrivateBrowserHost.Owner?, normalWindow: NSWindow?,
    normalTabID: String?, values: [String: Any] = [:]
  ) {
    var item: [String: Any] = [
      "stage": stage, "phase": phase, "runID": runID,
      "runtimeQuitting": runtime.isQuitting,
      "privateWindowCount": host?.windowCount ?? 0,
      "privateContextLive": owner.map {
        runtime.privateProbeAudit(forContextID: $0.contextID) != nil
      } ?? false,
      "privateWindowLive": owner.map {
        runtime.privateProbeAudit(forContextID: $0.contextID)?[
          "allWindowsNativeWindowsAlive"] as? Bool == true
      } ?? false,
      "normalWindowLive": normalWindow.map {
        runtime.window(forID: runtime.primaryWindowID) === $0
      } ?? false,
    ]
    if let owner {
      item["privateContextID"] = owner.contextID
      item["privateWindowID"] = owner.windowID
      item["privateQuitDialogCancelResult"] =
        runtime.privateProbeAudit(forContextID: owner.contextID)?[
          "privateQuitDialogCancelResult"] as? String ?? "unknown"
    }
    if let normalTabID {
      let selection = runtime.normalProbeSelectionAudit(forTabID: normalTabID)
      item["normalTabSelected"] =
        selection.isEmpty
        ? NSNull() : (selection["selectedNativeTab"] as? Bool == true)
      item["normalContentDisplayed"] =
        selection.isEmpty
        ? NSNull() : (selection["displayedNativeWebContents"] as? Bool == true)
    }
    item.merge(values) { _, new in new }
    quitDiagnosticStages.append(item)
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: [
          "schema": 1, "scope": "owned disposable private quit diagnostic",
          "stages": quitDiagnosticStages,
        ], options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(
      to: root.appending(path: "\(phase)-private-quit-diagnostic.json"), options: .atomic)
  }

  private func prepareNativeQuitCancellation(on tabID: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.preparePrivateQuitCancellationProbeTabID(tabID) { prepared in
        continuation.resume(returning: prepared)
      }
    }
  }

  private func cancelNativeBeforeUnload(on tabID: String) async -> Bool {
    await withCheckedContinuation { continuation in
      runtime.cancelPrivateQuitDialog(forProbeTabID: tabID) { cancelled in
        continuation.resume(returning: cancelled)
      }
    }
  }

  private func cancelQuitThroughNativeBeforeUnload(
    host: PrivateBrowserHost, owner: PrivateBrowserHost.Owner, normalWindow: NSWindow,
    normalTabID: String, closePrivateWindow: Bool
  ) async -> Bool {
    var observedQuit = false
    var attemptedPrivateClose = false
    var recordedDialogCancelResult = false
    var privateCloseTask: Task<NativeCloseReceipt, Never>?
    for _ in 0..<200 {
      if !runtime.isQuitting {
        if observedQuit {
          writeQuitDiagnostic(
            "quitFlagClearedBeforeDialogCancellation", owner: owner,
            normalWindow: normalWindow, normalTabID: normalTabID)
          return false
        }
        try? await Task.sleep(for: .milliseconds(50))
        continue
      }
      if !observedQuit {
        observedQuit = true
        writeQuitDiagnostic(
          "nativeQuitObserved", owner: owner, normalWindow: normalWindow,
          normalTabID: normalTabID)
      }
      if closePrivateWindow, !attemptedPrivateClose,
        let current = host.ownedWindows.first(where: { $0.windowID == owner.windowID })
      {
        attemptedPrivateClose = true
        writeQuitDiagnostic(
          "privateWindowCloseRequested", owner: current, normalWindow: normalWindow,
          normalTabID: normalTabID)
        privateCloseTask = Task { @MainActor in
          await self.closeNativeWindowReceipt(current)
        }
        await Task.yield()
      }
      let cancelled = await cancelNativeBeforeUnload(on: normalTabID)
      if !recordedDialogCancelResult {
        writeQuitDiagnostic(
          cancelled ? "nativeDialogCancellationCompleted" : "nativeDialogCancellationRejected",
          owner: owner, normalWindow: normalWindow, normalTabID: normalTabID,
          values: ["nativeDialogCancelReturned": cancelled])
        recordedDialogCancelResult = true
      }
      if cancelled {
        do {
          try await waitForQuitCancellation { !runtime.isQuitting }
          let survived =
            runtime.window(forID: runtime.primaryWindowID) === normalWindow
            && normalWindow.attachedSheet == nil
          var privateCloseConfirmed = !closePrivateWindow
          if let privateCloseTask {
            let receipt = await privateCloseTask.value
            privateCloseConfirmed = receipt.closed && receipt.requestedWhileQuitting
            writeQuitDiagnostic(
              privateCloseConfirmed
                ? "privateWindowOwnerCloseRequestedAndConfirmedWhileQuitting"
                : "privateWindowOwnerCloseRequestedWhileQuittingNotConfirmed",
              owner: owner, normalWindow: normalWindow, normalTabID: normalTabID,
              values: [
                "nativePrivateWindowCloseReturned": receipt.closed,
                "nativePrivateWindowCloseRequestedWhileQuitting":
                  receipt.requestedWhileQuitting,
                "nativePrivateWindowCloseConfirmedWhileQuitting":
                  receipt.confirmedWhileQuitting,
              ])
            if !privateCloseConfirmed,
              let current = host.ownedWindows.first(where: {
                $0.windowID == owner.windowID && $0.contextID == owner.contextID
              }), !runtime.isQuitting,
              runtime.privateProbeAudit(forContextID: owner.contextID) != nil
            {
              let closedAfterCancellation = await closeNativeWindow(current)
              privateCloseConfirmed =
                closedAfterCancellation
                && !host.ownedWindows.contains {
                  $0.windowID == owner.windowID && $0.contextID == owner.contextID
                }
                && runtime.privateProbeAudit(forContextID: owner.contextID) == nil
              writeQuitDiagnostic(
                privateCloseConfirmed
                  ? "privateWindowOwnerCloseConfirmedAfterQuitCancellation"
                  : "privateWindowOwnerCloseNotConfirmedAfterQuitCancellation",
                owner: owner, normalWindow: normalWindow, normalTabID: normalTabID,
                values: [
                  "nativePrivateWindowCloseReturned": closedAfterCancellation,
                  "nativePrivateWindowCloseConfirmedAfterQuitCancellation":
                    privateCloseConfirmed,
                ])
            }
            // A canceled explicit close can be followed by a confirmed engine close.
            if receipt.requestedWhileQuitting {
              let confirmed = await waitForNativeCloseObservation(owner)
              privateCloseConfirmed = confirmed
              writeQuitDiagnostic(
                confirmed
                  ? "privateWindowNativeCloseObserved"
                  : "privateWindowNativeCloseNotObserved",
                owner: owner, normalWindow: normalWindow, normalTabID: normalTabID,
                values: [
                  "explicitCloseReceiptClosed": receipt.closed,
                  "nativeCloseEventObserved": confirmed,
                  "nativeCloseEventObservedWhileQuitting":
                    nativeCloseObservations[owner.windowID]?.confirmedWhileQuitting ?? false,
                ])
            } else {
              privateCloseConfirmed = false
            }
          }
          writeQuitDiagnostic(
            "nativeQuitCancellationConfirmed", owner: owner,
            normalWindow: normalWindow, normalTabID: normalTabID,
            values: [
              "normalWindowSurvived": survived,
              "privateWindowCloseConfirmedWhileQuitting": privateCloseConfirmed,
            ])
          return survived && privateCloseConfirmed
        } catch {
          writeQuitDiagnostic(
            "nativeQuitCancellationTimedOut", owner: owner,
            normalWindow: normalWindow, normalTabID: normalTabID)
          return false
        }
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  private func waitForTabs(_ store: PrivateBrowserStore, count: Int) async throws {
    for _ in 0..<100 {
      if store.tabs.count == count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product tab callback timed out.")
  }

  private func waitForURL(_ store: PrivateBrowserStore, tabID: String, contains value: String)
    async throws
  {
    for _ in 0..<100 {
      if store.tabs.first(where: { $0.id == tabID })?.url.contains(value) == true { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product navigation callback timed out.")
  }

  private func capturePrivateWindow(
    _ owner: PrivateBrowserHost.Owner, runID: String, phase: String
  ) async throws -> (hostDigest: String, rendererDigest: String) {
    let view = owner.hosting
    guard view.window === owner.window, view.superview != nil else {
      throw PrivateWindowFailure("Private product window has no owned native view.")
    }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw PrivateWindowFailure("Private product screenshot bitmap could not be allocated.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), data.count > 4096 else {
      throw PrivateWindowFailure("Private product screenshot was empty or too small.")
    }
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "build/private-window-evidence/\(runID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appending(path: "product-\(phase).png"), options: .atomic)
    let tabID = owner.store.selectedTabID
    guard let viewportAudit = runtime.privateProbeAudit(forContextID: owner.contextID) else {
      throw PrivateWindowFailure(
        "Private native viewport audit unavailable before renderer capture.")
    }
    rendererViewportAudit = Dictionary(
      uniqueKeysWithValues: viewportAudit.map { (String(describing: $0.key), $0.value) })
    guard viewportAudit["allWindowsNativeWindowsAlive"] as? Bool == true,
      viewportAudit["allWindowsDisplayOwnedWebContents"] as? Bool == true,
      viewportAudit["visibleNativeViewportCount"] as? Int == 1
    else {
      throw PrivateWindowFailure(
        "Private native viewport ownership audit failed before renderer capture: \(rendererViewportAudit)."
      )
    }
    let (rendererData, captureOutcome): (Data?, String?) = await withCheckedContinuation {
      continuation in
      runtime.capturePrivateProbeTabID(tabID, windowID: owner.windowID, contextID: owner.contextID)
      {
        data, outcome in
        continuation.resume(returning: (data, outcome))
      }
    }
    rendererCaptureOutcome = captureOutcome ?? "captured"
    guard let rendererData, rendererData.count > 4096,
      rendererData.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    else {
      throw PrivateWindowFailure(
        "Owned private renderer screenshot missing or invalid; CDP outcome: \(rendererCaptureOutcome)."
      )
    }
    try rendererData.write(
      to: directory.appending(path: "renderer-product-\(phase).png"), options: .atomic)
    let hostDigest = sha256(data)
    let rendererDigest = sha256(rendererData)
    return (hostDigest: hostDigest, rendererDigest: rendererDigest)
  }

  private func waitForNativeCloseObservation(_ owner: PrivateBrowserHost.Owner) async -> Bool {
    for _ in 0..<100 {
      if nativeCloseObservations[owner.windowID]?.contextID == owner.contextID {
        return true
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  private func closeNativeWindow(_ owner: PrivateBrowserHost.Owner) async -> Bool {
    await closeNativeWindowReceipt(owner).closed
  }

  private func closeNativeWindowReceipt(_ owner: PrivateBrowserHost.Owner) async
    -> NativeCloseReceipt
  {
    let requestedWhileQuitting = runtime.isQuitting
    return await withCheckedContinuation { continuation in
      runtime.closePrivateWindowID(owner.windowID, contextID: owner.contextID) {
        continuation.resume(
          returning: NativeCloseReceipt(
            closed: $0, requestedWhileQuitting: requestedWhileQuitting,
            confirmedWhileQuitting: self.runtime.isQuitting))
      }
    }
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
