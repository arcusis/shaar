// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct NativeActivationFeedbackTests {
  @Test func acknowledgingSelectedTabDoesNotScheduleAnotherActivation() async throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/selected")!))
    let tab = try #require(store.session.selectedPage?.tab.id)
    let runtime = ActivationFeedbackRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "feedback-window", store: store,
      presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs.insert(tab)
    #expect(engine.events.router.bindTab(tab.uuidString, windowID: engine.windowID))
    runtime.onTabActivated?(tab.uuidString, store.session.selectedSpace.profileID.uuidString)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    #expect(runtime.activations.isEmpty)
    #expect(runtime.restoredTabs == [tab.uuidString])
  }

  @Test func activationDuringReconcileKeepsTheLatestTarget() throws {
    let profile = BrowserProfile(name: "Company")
    let first = BrowserTab(url: URL(string: "https://example.com/first")!)
    let target = BrowserTab(url: URL(string: "https://example.com/target")!)
    let source = BrowserSpace(
      profileID: profile.id, name: "Source", symbol: "house", tint: .ocean, tabs: [first])
    let destination = BrowserSpace(
      profileID: profile.id, name: "Shared", symbol: "folder", tint: .forest, tabs: [target])
    let session = try BrowserSession(
      profiles: [profile], spaces: [source, destination], selectedSpaceID: source.id)
    let store = BrowserStore(session: session)
    let runtime = ReenteredActivationRuntime(
      initialTab: first.id.uuidString, reenterTarget: target.id.uuidString,
      reenterProfile: profile.id.uuidString)
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "feedback-window", store: store,
      presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs.insert(first.id)
    engine.liveTabs.insert(target.id)
    #expect(engine.events.router.bindTab(first.id.uuidString, windowID: engine.windowID))
    #expect(engine.events.router.bindTab(target.id.uuidString, windowID: engine.windowID))
    engine.reconcile()
    #expect(store.session.selectedSpaceID == destination.id)
    #expect(store.session.selectedPage?.tab.id == target.id)
  }
}

private final class ReenteredActivationRuntime: ARCChromiumRuntime, @unchecked Sendable {
  let initialTab: String
  let reenterTarget: String
  let reenterProfile: String
  nonisolated(unsafe) private var didReenter = false

  init(initialTab: String, reenterTarget: String, reenterProfile: String) {
    self.initialTab = initialTab
    self.reenterTarget = reenterTarget
    self.reenterProfile = reenterProfile
    super.init()
  }

  override func windowID(forTabID tabID: String) -> String? { "feedback-window" }
  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {}
  override func view(forTabID tabID: String) -> NSView? { nil }
  override func activateTabID(_ tabID: String) {
    let tab = tabID
    MainActor.assumeIsolated {
      guard !self.didReenter, tab == self.initialTab else { return }
      self.didReenter = true
      self.onTabActivated?(self.reenterTarget, self.reenterProfile)
    }
  }
}

private final class ActivationFeedbackRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var activations: [String] = []
  nonisolated(unsafe) var restoredTabs: [String] = []
  override func windowID(forTabID tabID: String) -> String? { "feedback-window" }
  override func activateTabID(_ tabID: String) { activations.append(tabID) }
  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {}
  override func view(forTabID tabID: String) -> NSView? {
    restoredTabs.append(tabID)
    return nil
  }
}
