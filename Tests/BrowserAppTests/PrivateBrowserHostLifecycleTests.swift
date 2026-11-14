// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor
private final class PrivateHostLifecycleRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var windows: [String: NSWindow] = [:]
  nonisolated(unsafe) var containers: [String: NSView] = [:]
  nonisolated(unsafe) var createdContexts: [String] = []
  nonisolated(unsafe) var releasedContexts: [String] = []
  var holdsContextCreation = false
  var contextCompletion: (@MainActor @Sendable (Bool, Error?) -> Void)?
  nonisolated(unsafe) var failedWindowCreations = 0
  nonisolated(unsafe) var failedContextReleases = 0
  nonisolated(unsafe) var missingPrivateWindow = false

  override func createPrivateContextID(
    _ contextID: String, sourceProfileID: String,
    completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
  ) {
    createdContexts.append(contextID)
    if holdsContextCreation {
      contextCompletion = completion
    } else {
      completion(true, nil)
    }
  }

  override func createPrivateWindowID(
    _ windowID: String, contextID: String, tabID: String, url: String
  ) throws {
    if failedWindowCreations > 0 {
      failedWindowCreations -= 1
      throw NSError(domain: "PrivateHostLifecycleRuntime", code: 1)
    }
    let window = MainActor.assumeIsolated {
      NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }
    let container = MainActor.assumeIsolated {
      NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }
    windows[windowID] = window
    containers[windowID] = container
  }

  override func window(forPrivateWindowID windowID: String, contextID: String) -> NSWindow? {
    if missingPrivateWindow { return nil }
    return windows[windowID]
  }

  override func hostView(forPrivateWindowID windowID: String, contextID: String) -> NSView? {
    containers[windowID]
  }

  override func closePrivateWindowID(
    _ windowID: String, contextID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    windows.removeValue(forKey: windowID)
    containers.removeValue(forKey: windowID)
    completion(false)
  }

  override func releasePrivateContextID(_ contextID: String) -> Bool {
    releasedContexts.append(contextID)
    if failedContextReleases > 0 {
      failedContextReleases -= 1
      return false
    }
    return true
  }
}

@Suite @MainActor
struct PrivateBrowserHostLifecycleTests {
  @Test func failedContextCreationReportsErrorAndDropsQueuedWindows() throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.holdsContextCreation = true
    let sourceProfileID = UUID().uuidString
    var reportedErrors: [Error] = []
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      reportError: { reportedErrors.append($0) },
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()
    try host.openWindow()
    let completion = try #require(runtime.contextCompletion)
    completion(false, NSError(domain: "PrivateHostLifecycleRuntime", code: 2))

    #expect(host.windowCount == 0)
    #expect(runtime.createdContexts.count == 1)
    #expect(reportedErrors.count == 1)
    #expect((reportedErrors.first as NSError?)?.code == 2)
    host.detach()
  }

  @Test func fullScreenMenuCommandRoutesToActivePrivateWindow() throws {
    let runtime = PrivateHostLifecycleRuntime()
    let sourceProfileID = UUID().uuidString
    var activeWindow: NSWindow?
    var toggledWindow: NSWindow?
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false, keyWindow: { activeWindow },
      toggleFullScreen: { toggledWindow = $0 }, sourceProfileID: { sourceProfileID })
    host.installCallbacks()
    try host.openWindow()
    activeWindow = try #require(host.ownedWindows.first?.window)

    host.perform(.fullScreen)

    #expect(toggledWindow === activeWindow)
    host.detach()
  }

  @Test func completingContextCreationAfterDetachDoesNotCreateAWindow() throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.holdsContextCreation = true
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()
    try host.openWindow()
    let contextID = try #require(runtime.createdContexts.first)
    let completion = try #require(runtime.contextCompletion)

    host.detach()
    completion(true, nil)

    #expect(host.windowCount == 0)
    #expect(runtime.windows.isEmpty)
    #expect(runtime.releasedContexts == [contextID])
  }

  @Test func failedContextReleaseAfterDetachIsRetriedImmediately() throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.holdsContextCreation = true
    runtime.failedContextReleases = 1
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()
    try host.openWindow()
    let contextID = try #require(runtime.createdContexts.first)
    let completion = try #require(runtime.contextCompletion)

    host.detach()
    completion(true, nil)

    #expect(host.windowCount == 0)
    #expect(runtime.windows.isEmpty)
    #expect(runtime.releasedContexts == [contextID, contextID])
  }

  @Test func contextReleaseKeepsRetryingAfterDetachedHostCreationCompletes() async throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.holdsContextCreation = true
    runtime.failedContextReleases = 2
    let sourceProfileID = UUID().uuidString
    var host: PrivateBrowserHost? = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host?.installCallbacks()
    try host?.openWindow()
    let contextID = try #require(runtime.createdContexts.first)
    let completion = try #require(runtime.contextCompletion)

    host?.detach()
    host = nil
    completion(true, nil)
    for _ in 0..<300 where runtime.releasedContexts.count < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(runtime.windows.isEmpty)
    #expect(runtime.releasedContexts == [contextID, contextID, contextID])
  }

  @Test func pendingReleaseRetrySurvivesHostDeallocation() async throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.holdsContextCreation = true
    runtime.failedContextReleases = 2
    let sourceProfileID = UUID().uuidString
    var host: PrivateBrowserHost? = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host?.installCallbacks()
    try host?.openWindow()
    let contextID = try #require(runtime.createdContexts.first)
    let completion = try #require(runtime.contextCompletion)

    host?.detach()
    completion(true, nil)
    host = nil
    for _ in 0..<300 where runtime.releasedContexts.count < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(runtime.windows.isEmpty)
    #expect(runtime.releasedContexts == [contextID, contextID, contextID])
  }

  @Test func failedQueuedWindowCreationDoesNotReleaseContextNeededByNextRequest() throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.holdsContextCreation = true
    runtime.failedWindowCreations = 1
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()
    try host.openWindow()
    let contextID = try #require(runtime.createdContexts.first)
    let completion = try #require(runtime.contextCompletion)
    completion(true, nil)

    #expect(host.windowCount == 1)
    #expect(host.ownedWindows.first?.contextID == contextID)
    #expect(runtime.releasedContexts.isEmpty)

    let windowID = try #require(host.ownedWindows.first?.windowID)
    runtime.onPrivateWindowClosed?(contextID, windowID)
    #expect(runtime.releasedContexts == [contextID])
    host.detach()
  }

  @Test func missingNativeWindowStillReleasesEmptyPrivateContext() throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.missingPrivateWindow = true
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()

    #expect(host.windowCount == 0)
    #expect(runtime.releasedContexts == runtime.createdContexts)
    host.detach()
  }

  @Test func failedContextReleaseIsRetriedBeforeCreatingAnotherPrivateContext() throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.failedContextReleases = 1
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()
    let first = try #require(host.ownedWindows.first)
    runtime.onPrivateWindowClosed?(first.contextID, first.windowID)
    #expect(runtime.releasedContexts == [first.contextID])

    try host.openWindow()

    #expect(runtime.releasedContexts == [first.contextID, first.contextID])
    #expect(runtime.createdContexts.count == 2)
    #expect(runtime.createdContexts[1] != first.contextID)
    host.detach()
  }

  @Test func failedContextReleaseRetriesWithoutAnotherWindowRequest() async throws {
    let runtime = PrivateHostLifecycleRuntime()
    runtime.failedContextReleases = 1
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()
    let owner = try #require(host.ownedWindows.first)
    runtime.onPrivateWindowClosed?(owner.contextID, owner.windowID)

    for _ in 0..<150 where runtime.releasedContexts.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.releasedContexts == [owner.contextID, owner.contextID])
    #expect(host.windowCount == 0)
    host.detach()
  }

  @Test func closingOneOfSeveralPrivateWindowsKeepsContextUntilTheLastWindowCloses() throws {
    let runtime = PrivateHostLifecycleRuntime()
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()
    try host.openWindow()
    let owners = host.ownedWindows
    #expect(owners.count == 2)
    #expect(Set(owners.map(\.contextID)).count == 1)
    let contextID = try #require(owners.first?.contextID)

    runtime.onPrivateWindowClosed?(contextID, owners[0].windowID)
    #expect(host.windowCount == 1)
    #expect(runtime.releasedContexts.isEmpty)

    runtime.onPrivateWindowClosed?(contextID, owners[1].windowID)
    #expect(host.windowCount == 0)
    #expect(runtime.releasedContexts == [contextID])
    host.detach()
  }
}
