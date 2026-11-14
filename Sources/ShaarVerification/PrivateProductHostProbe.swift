// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import ChromiumBridgeVerification
import CryptoKit
import Foundation
import SwiftUI

@testable import ArcusisBrowser

@MainActor
final class PrivateProductHostProbe {
  struct Evidence {
    let checks: [String: Bool]
    let expectedFailures: [String: String]
    let workspaceSHA256: String
    let screenshotSHA256: String
    let rendererScreenshotSHA256: String
    let rendererViewportAudit: [String: Any]
    let rendererCaptureOutcome: String
    let smokeDiagnostics: [String: Any]
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
  private weak var keyWindow: NSWindow?
  private var host: PrivateBrowserHost?
  private var checks: [String: Bool] = [:]
  private var expectedFailures: [String: String] = [:]
  private var workspaceBytes = Data()
  private var screenshotDigest = ""
  private var rendererScreenshotDigest = ""
  private var rendererViewportAudit: [String: Any] = [:]
  private var rendererCaptureOutcome = "not-attempted"
  private var smokeDiagnostics: [String: Any] = [:]
  private var lifecycleBlocker = ""
  private var quitDiagnosticStages: [[String: Any]] = []
  private var nativeCloseObservations: [String: NativeCloseObservation] = [:]
  private weak var lifecycleStore: BrowserStore?
  private weak var lifecycleHosting: NSHostingView<BrowserWindow?>?

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
        checks: checks, expectedFailures: expectedFailures,
        workspaceSHA256: sha256(after), screenshotSHA256: screenshotDigest,
        rendererScreenshotSHA256: rendererScreenshotDigest,
        rendererViewportAudit: rendererViewportAudit,
        rendererCaptureOutcome: rendererCaptureOutcome,
        smokeDiagnostics: smokeDiagnostics,
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
    guard beforeUnloadActivated else {
      throw PrivateWindowFailure(
        "Normal fixture page could not arm beforeunload with renderer user activation.")
    }
    let quitCancellationPrepared = await prepareNativeQuitCancellation(on: normalTabID)
    writeQuitDiagnostic(
      "nativeQuitCancellationPreparation", owner: quitOwner, normalWindow: normalWindow,
      normalTabID: normalTabID,
      values: [
        "beforeUnloadActivated": beforeUnloadActivated,
        "beforeUnloadHandlerInstalled": beforeUnloadHandlerInstalled,
        "nativeQuitCancellationPrepared": quitCancellationPrepared,
      ])
    guard quitCancellationPrepared else {
      throw PrivateWindowFailure(
        "Normal fixture page could not prepare native quit cancellation "
          + "after beforeunload was armed.")
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
    let privateContainer = runtime.hostView(
      forPrivateWindowID: first.windowID, contextID: first.contextID)
    var hostingRemainedAttached = Self.hostingViewIsAttached(
      first.hosting, to: privateContainer, in: first.window)
    checks["productHostOwnsPrivateNativeWindow"] =
      first.store.windowID == first.windowID
      && first.store.contextID == first.contextID
      && first.hosting.rootView?.store === first.store
      && hostingRemainedAttached
      && nativePageView != nil && first.store.showsStartPage

    try await captureStartPage(first)
    let firstVisit = "private-product-\(runID.lowercased())-a"
    let nextVisit = "private-product-\(runID.lowercased())-next"
    let firstPath = fixture.appending(path: firstVisit).absoluteString
    let alphabetQuery =
      fixture.appending(
        path: "private-product-\(runID.lowercased())-search"
      ).absoluteString + "?q=abcdefghijklmnopqrstuvwxyz"
    first.store.showAddressEditor()
    first.hosting.layoutSubtreeIfNeeded()
    let appWindowCount = NSApp.windows.count
    let appWindowIDsBeforeTyping = Set(NSApp.windows.map { ObjectIdentifier($0) })
    let typedQuery = typeInAddressField(alphabetQuery, window: first.window, hosting: first.hosting)
    let addedWindows = NSApp.windows.filter {
      !appWindowIDsBeforeTyping.contains(ObjectIdentifier($0))
    }
    let openedPickerWindow = addedWindows.contains { $0.isVisible || $0 is NSPanel }
    smokeDiagnostics["alphabetSearch"] = [
      "typedQuery": typedQuery.map { $0 as Any } ?? NSNull(), "expectedQuery": alphabetQuery,
      "commandIsOpen": first.store.commandIsOpen, "tabCount": first.store.tabs.count,
      "privateWindowCount": privateHost.windowCount, "appWindowCountBefore": appWindowCount,
      "appWindowCountAfter": NSApp.windows.count,
      "openedPickerWindow": openedPickerWindow,
      "windows": NSApp.windows.map { window in
        [
          "class": String(reflecting: type(of: window)), "title": window.title,
          "visible": window.isVisible, "panel": window is NSPanel,
          "level": window.level.rawValue, "styleMask": window.styleMask.rawValue,
        ]
      },
    ]
    checks["productAlphabetSearchDoesNotOpenPicker"] =
      typedQuery == alphabetQuery && first.store.commandIsOpen && !openedPickerWindow
      && first.store.tabs.count == 1 && privateHost.windowCount == 1
    submitAddressField(window: first.window)
    first.store.confirmHTTP(useHTTPS: false)
    try await waitForURL(
      first.store, tabID: first.store.selectedTabID, contains: "q=abcdefghijklmnopqrstuvwxyz")
    first.store.openTab()
    try await waitForTabs(first.store, count: 2)
    hostingRemainedAttached = hostingRemainedAttached
      && Self.hostingViewIsAttached(first.hosting, to: privateContainer, in: first.window)
    guard let secondTab = first.store.selectedTab else {
      throw PrivateWindowFailure("Private Command-T did not select transient tab.")
    }
    checks["productPrivateFocusUsesOwnedTab"] = runtime.focusPrivateTabID(
      secondTab.id, windowID: first.windowID, contextID: first.contextID)
    let firstTabID = first.store.tabs.first(where: { $0.id != secondTab.id })?.id
    if let firstTabID {
      first.store.selectTab(firstTabID)
      hostingRemainedAttached = hostingRemainedAttached
        && Self.hostingViewIsAttached(first.hosting, to: privateContainer, in: first.window)
      first.store.selectTab(secondTab.id)
      hostingRemainedAttached = hostingRemainedAttached
        && Self.hostingViewIsAttached(first.hosting, to: privateContainer, in: first.window)
    }
    first.store.navigate(firstPath)
    first.store.confirmHTTP(useHTTPS: false)
    try await waitForURL(first.store, tabID: secondTab.id, contains: firstVisit)
    let nextPath = fixture.appending(path: nextVisit).absoluteString
    first.store.navigate(nextPath)
    first.store.confirmHTTP(useHTTPS: false)
    try await waitForURL(first.store, tabID: secondTab.id, contains: nextVisit)
    try await waitForTab(first.store, tabID: secondTab.id, canGoBack: true)
    first.store.goBack()
    try await waitForURL(first.store, tabID: secondTab.id, contains: firstVisit)
    first.store.goForward()
    try await waitForURL(first.store, tabID: secondTab.id, contains: nextVisit)
    first.store.reload()
    try await waitForLoading(first.store, tabID: secondTab.id, loading: true)
    try await waitForLoading(first.store, tabID: secondTab.id, loading: false)
    checks["productPrivateNavigationReloadBackForwardCallbacks"] =
      firstTabID != nil && first.store.selectedTabID == secondTab.id
      && first.store.tabs.first(where: { $0.id == secondTab.id })?.url.contains("-next") == true
    privateHost.perform(.newTab)
    checks["productCommandTUsesPrivateOpaqueSearch"] =
      privateHost.activeOwner?.windowID == first.windowID
      && privateHost.canPerform(.newTab) && first.store.commandIsOpen
      && first.store.tabs.count == 2
    first.store.dismissCommand()
    first.store.openTab()
    try await waitForTabs(first.store, count: 3)
    hostingRemainedAttached = hostingRemainedAttached
      && Self.hostingViewIsAttached(first.hosting, to: privateContainer, in: first.window)
    guard let commandTab = first.store.selectedTab else {
      throw PrivateWindowFailure("Private Command-T did not create a selected native tab.")
    }
    checks["productCommandTUsesPrivateOpaqueSearch"] =
      checks["productCommandTUsesPrivateOpaqueSearch"] == true
      && first.store.showsStartPage && commandTab.id != secondTab.id
    privateHost.perform(.search)
    checks["productCommandLTargetsCurrentPrivateTab"] =
      first.store.tabs.count == 3
      && first.store.selectedTabID == commandTab.id && first.store.commandIsOpen
    first.store.commandQuery =
      fixture.appending(
        path: "private-product-\(runID.lowercased())-command-t"
      ).absoluteString
    first.store.submitCommand()
    first.store.confirmHTTP(useHTTPS: false)
    try await waitForURL(first.store, tabID: commandTab.id, contains: "-command-t")
    try await waitForCaptureReadiness(first, tabID: commandTab.id)
    first.store.dismissCommand()
    for (index, tabID) in first.store.tabs.map(\.id).enumerated() {
      let path = "private-product-\(runID.lowercased())-smoke-\(index + 1)"
      first.store.selectTab(tabID)
      hostingRemainedAttached = hostingRemainedAttached
        && Self.hostingViewIsAttached(first.hosting, to: privateContainer, in: first.window)
      first.store.navigate(fixture.appending(path: path).absoluteString)
      first.store.confirmHTTP(useHTTPS: false)
      try await waitForURL(first.store, tabID: tabID, contains: path)
      try await waitForCaptureReadiness(first, tabID: tabID)
      let renders = await privateTabRenders(owner: first, tabID: tabID, path: path)
      switch index {
      case 0: checks["productFirstPrivateTabRenders"] = renders
      case 1:
        checks["productSecondPrivateTabRenders"] = renders
        if !renders {
          expectedFailures["productSecondPrivateTabRenders"] =
            "Issue #417: second private tab may display a black page."
        }
      case 2: checks["productThirdPrivateTabRenders"] = renders
      default: break
      }
    }
    checks["productPrivateHostRemainsAttachedAcrossTabs"] = hostingRemainedAttached
    if let firstTabID, let firstTabUUID = UUID(uuidString: firstTabID) {
      first.store.closeTab(firstTabUUID)
      try await waitForTabs(first.store, count: 2)
      checks["productPrivateHostRemainsAttachedAfterTabClose"] =
        Self.hostingViewIsAttached(first.hosting, to: privateContainer)
    } else {
      checks["productPrivateHostRemainsAttachedAfterTabClose"] = false
    }
    first.store.showCommand()
    try await waitForCaptureReadiness(first, tabID: first.store.selectedTabID)
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

  private func captureStartPage(_ owner: PrivateBrowserHost.Owner) async throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "build/private-window-evidence/\(runID)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      owner.window.appearance = NSAppearance(named: appearance)
      owner.hosting.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      guard !owner.window.isVisible,
        let bitmap = owner.hosting.bitmapImageRepForCachingDisplay(in: owner.hosting.bounds)
      else { throw PrivateWindowFailure("Private start page must remain offscreen.") }
      owner.hosting.cacheDisplay(in: owner.hosting.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 4096
      else { throw PrivateWindowFailure("Private start page capture was empty.") }
      try png.write(to: directory.appending(path: "start-\(phase)-\(name).png"))
    }
    owner.window.appearance = nil
  }

  static func hostingViewIsAttached(
    _ hostingView: NSView, to container: NSView?, in window: NSWindow
  ) -> Bool {
    guard let container else { return false }
    return hostingView.superview === container && container.window === window
      && hostingView.window === window
  }

  private func typeInAddressField(
    _ text: String, window: NSWindow, hosting: NSHostingView<BrowserWindow?>
  ) -> String? {
    func textFields(in view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
    guard let field = textFields(in: hosting).first,
      window.makeFirstResponder(field),
      let editor = window.fieldEditor(true, for: field) as? NSTextView
    else { return nil }
    editor.string = ""
    guard let alphabet = text.range(of: "abcdefghijklmnopqrstuvwxyz") else { return nil }
    let prefix = String(text[..<alphabet.lowerBound])
    editor.insertText(prefix, replacementRange: editor.selectedRange())
    for character in text[alphabet] {
      guard let event = keyEvent(for: character, window: window) else { return nil }
      window.sendEvent(event)
    }
    return field.stringValue
  }

  private func submitAddressField(window: NSWindow) {
    guard
      let enter = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
    else { return }
    window.sendEvent(enter)
  }

  private func keyEvent(for character: Character, window: NSWindow) -> NSEvent? {
    let keyCode: UInt16? =
      switch character {
      case "a": 0
      case "b": 11
      case "c": 8
      case "d": 2
      case "e": 14
      case "f": 3
      case "g": 5
      case "h": 4
      case "i": 34
      case "j": 38
      case "k": 40
      case "l": 37
      case "m": 46
      case "n": 45
      case "o": 31
      case "p": 35
      case "q": 12
      case "r": 15
      case "s": 1
      case "t": 17
      case "u": 32
      case "v": 9
      case "w": 13
      case "x": 7
      case "y": 16
      case "z": 6
      default: nil
      }
    guard let keyCode else { return nil }
    let value = String(character)
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: value,
      charactersIgnoringModifiers: value, isARepeat: false, keyCode: keyCode)
  }

  private func waitForTab(
    _ store: BrowserStore, tabID: String, canGoBack: Bool
  ) async throws {
    for _ in 0..<100 {
      if store.tabs.first(where: { $0.id == tabID })?.canGoBack == canGoBack { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product navigation state callback timed out.")
  }

  private func waitForLoading(
    _ store: BrowserStore, tabID: String, loading: Bool
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
        continuation.resume(
          returning: Self.historyExcludesProductVisit(rows: rows, error: error, runID: self.runID))
      }
    }
  }

  static func historyExcludesProductVisit(
    rows: [[AnyHashable: Any]]?, error: Error?, runID: String
  ) -> Bool {
    guard error == nil, let rows else { return false }
    return !rows.contains {
      ($0["u"] as? String)?.contains("private-product-\(runID.lowercased())") == true
    }
  }

  private func waitForWindows(_ privateHost: PrivateBrowserHost, count: Int) async throws {
    for _ in 0..<100 {
      if privateHost.windowCount == count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product native window ownership timed out.")
  }

  /// Window teardown runs on the engine's schedule; slower machines stretch this wait.
  private func waitForOwnerDeallocation() async throws {
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      if lifecycleStore == nil && lifecycleHosting == nil { return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func waitForQuitCancellation(_ cancelled: () -> Bool) async throws {
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
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
    guard clicked, await waitForTrustedQuitActivation(on: tabID) else { return false }
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

  private func waitForTrustedQuitActivation(on tabID: String) async -> Bool {
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      let activated: Bool = await withCheckedContinuation { continuation in
        runtime.evaluate(
          inTabID: tabID,
          script:
            "navigator.userActivation.hasBeenActive && window.__arcusisQuitClickTrusted === true"
        ) { result in
          continuation.resume(returning: result == "true")
        }
      }
      if activated { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
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
      item["privateQuitPreparationResult"] =
        runtime.privateProbeAudit(forContextID: owner.contextID)?[
          "privateQuitPreparationResult"] as? String ?? "unknown"
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

  private func waitForTabs(_ store: BrowserStore, count: Int) async throws {
    for _ in 0..<100 {
      if store.tabs.count == count { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Private product tab callback timed out.")
  }

  private func waitForURL(_ store: BrowserStore, tabID: String, contains value: String)
    async throws
  {
    let attempts = Int(100 * ProbeTimeout.scale)
    for _ in 0..<attempts {
      let tab = store.tabs.first { $0.id == tabID }
      if PrivateNavigationReadiness.hasSettled(
        url: tab?.url,
        loading: tab?.loading ?? true,
        phase: navigationPhase(for: tabID),
        contains: value
      ) {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let observed = store.tabs.first(where: { $0.id == tabID })?.url ?? "missing tab"
    let nativeFailure = store.privatePage?.failure ?? "none"
    let pipeline = runtime.privateNavigationProbeAudit(forTabID: tabID) ?? [:]
    let nativeDocument = nativeNavigationSnapshot(tabID: tabID, contextID: store.contextID)
    throw PrivateWindowFailure(
      "Private product navigation callback timed out: expected \(value), observed \(observed), selected tab \(store.selectedTabID), native failure \(nativeFailure), pipeline \(pipeline), native document \(nativeDocument)."
    )
  }

  private func navigationPhase(for tabID: String) -> String? {
    let audit = runtime.privateNavigationProbeAudit(forTabID: tabID)
    return audit?["lastEventPhase"] as? String
  }

  private func nativeNavigationSnapshot(tabID: String, contextID: String) -> String {
    guard
      let audit = runtime.privateProbeAudit(forContextID: contextID),
      let documents = audit["documentStates"] as? [[AnyHashable: Any]],
      let document = documents.first(where: { $0["tabID"] as? String == tabID })
    else { return "unavailable" }
    let url = document["url"] as? String ?? "unknown"
    let requested = document["requestedURL"] as? String ?? "unknown"
    let phase = document["phase"] as? String ?? "unknown"
    let loading = document["loading"] as? Bool ?? false
    return "url=\(url), requested=\(requested), phase=\(phase), loading=\(loading)"
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
    var (rendererData, captureOutcome): (Data?, String?) = await captureOwnedRenderer(
      owner, tabID: tabID)
    if rendererData == nil {
      // A native capture can time out while the selected WebContents is still
      // settling after its ownership audit. Reconfirm readiness before one
      // bounded retry; the phase still requires a real renderer PNG below.
      try await waitForCaptureReadiness(owner, tabID: tabID)
      guard let retryAudit = runtime.privateProbeAudit(forContextID: owner.contextID),
        retryAudit["allWindowsNativeWindowsAlive"] as? Bool == true,
        retryAudit["allWindowsDisplayOwnedWebContents"] as? Bool == true,
        retryAudit["visibleNativeViewportCount"] as? Int == 1
      else {
        throw PrivateWindowFailure(
          "Private native viewport ownership changed before renderer capture retry.")
      }
      (rendererData, captureOutcome) = await captureOwnedRenderer(owner, tabID: tabID)
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

  private func captureOwnedRenderer(
    _ owner: PrivateBrowserHost.Owner, tabID: String
  ) async -> (Data?, String?) {
    await withCheckedContinuation { continuation in
      runtime.capturePrivateProbeTabID(
        tabID, windowID: owner.windowID, contextID: owner.contextID
      ) { data, outcome in
        continuation.resume(returning: (data, outcome))
      }
    }
  }

  private func privateTabRenders(
    owner: PrivateBrowserHost.Owner, tabID: String, path: String
  ) async -> Bool {
    guard owner.store.selectedTabID == tabID,
      runtime.selectPrivateTabID(tabID, windowID: owner.windowID, contextID: owner.contextID)
    else {
      smokeDiagnostics["render-\(path)"] = ["selected": false]
      return false
    }
    let document: String? = await withCheckedContinuation { continuation in
      runtime.evaluatePrivateProbeTabID(
        tabID,
        script:
          "document.readyState==='complete'&&location.pathname==='\(fixture.appending(path: path).path)'&&document.body.innerText.includes('OrbitFindMarker')"
      ) { continuation.resume(returning: $0) }
    }
    guard document == "true" else {
      smokeDiagnostics["render-\(path)"] = [
        "selected": true, "document": document.map { $0 as Any } ?? NSNull(),
      ]
      return false
    }
    let (screenshot, outcome): (Data?, String?) = await withCheckedContinuation {
      continuation in
      runtime.capturePrivateProbeTabID(tabID, windowID: owner.windowID, contextID: owner.contextID)
      { data, outcome in continuation.resume(returning: (data, outcome)) }
    }
    guard outcome == nil || outcome == "captured", let screenshot,
      let bitmap = NSBitmapImageRep(data: screenshot), bitmap.pixelsWide > 0,
      bitmap.pixelsHigh > 0
    else {
      smokeDiagnostics["render-\(path)"] = [
        "selected": true, "document": document.map { $0 as Any } ?? NSNull(),
        "captureOutcome": outcome ?? "nil",
        "captureBytes": screenshot?.count ?? 0,
      ]
      return false
    }
    var nonBlackSamples = 0
    let stride = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 16)
    for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: stride) {
      for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: stride) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        if color.redComponent + color.greenComponent + color.blueComponent > 0.15 {
          nonBlackSamples += 1
        }
      }
    }
    smokeDiagnostics["render-\(path)"] = [
      "selected": true, "document": document.map { $0 as Any } ?? NSNull(),
      "captureOutcome": outcome ?? "nil",
      "captureBytes": screenshot.count, "width": bitmap.pixelsWide,
      "height": bitmap.pixelsHigh, "nonBlackSamples": nonBlackSamples,
    ]
    return nonBlackSamples > 8
  }

  private func waitForCaptureReadiness(_ owner: PrivateBrowserHost.Owner, tabID: String)
    async throws
  {
    for _ in 0..<Int(100 * ProbeTimeout.scale) {
      if runtime.privateProbeCaptureIsReady(
        forTabID: tabID, windowID: owner.windowID, contextID: owner.contextID)
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw PrivateWindowFailure("Selected private renderer did not become ready for capture.")
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
