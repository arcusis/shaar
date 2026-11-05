// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SettingsOpenSpaceTests: XCTestCase {
  func testSettingsCreatesSavedWindowOnRequestedSpaceWhenAllWindowsAreClosed() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    let requestedSpaceID = try XCTUnwrap(workspace.workspace.catalog.spaces.last?.id)
    for windowID in Array(workspace.stores.keys) { try workspace.removeWindow(windowID) }
    try workspace.flushSaves()
    XCTAssertTrue(workspace.workspace.windows.isEmpty)

    let host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), workspace: workspace,
      presentation: .hiddenProbe, keyWindow: { nil }, screens: { [] })
    let windowID = try host.createWorkspaceWindowForSettingsSpace(requestedSpaceID)

    XCTAssertEqual(workspace.workspace.windows.count, 1)
    XCTAssertEqual(workspace.stores[windowID]?.session.selectedSpaceID, requestedSpaceID)
    try workspace.flushSaves()
    XCTAssertEqual(try file.load()?.window(windowID)?.session.selectedSpaceID, requestedSpaceID)
  }

  func testSettingsOpenRollsBackCreatedWindowWhenNativeAttachFails() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = WorkspaceFile(
      url: root.appending(path: "workspace.json"),
      legacySessionURL: root.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    let requestedSpaceID = try XCTUnwrap(workspace.workspace.catalog.spaces.last?.id)
    for windowID in Array(workspace.stores.keys) { try workspace.removeWindow(windowID) }
    try workspace.flushSaves()

    let host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), workspace: workspace,
      presentation: .hiddenProbe, keyWindow: { nil }, screens: { [] })
    host.openSpaceFromSettings(requestedSpaceID)

    XCTAssertTrue(workspace.workspace.windows.isEmpty)
    XCTAssertTrue(host.contexts.isEmpty)
    XCTAssertNotNil(host.lastError)
  }

  func testHiddenSettingsOpenSpaceDoesNotOrderBrowserWindow() throws {
    _ = NSApplication.shared
    let runtime = SettingsWindowRuntime()
    let workspace = try BrowserWorkspaceStore(initialSession: .fresh())
    let requestedSpaceID = try XCTUnwrap(workspace.workspace.catalog.spaces.last?.id)
    let host = NativeBrowserHost(
      events: BrowserRuntimeEvents(runtime: runtime), workspace: workspace,
      presentation: .hiddenProbe, usesPrimaryWindow: false)
    defer { host.detach() }
    try host.restore()
    let window = try XCTUnwrap(runtime.createdWindow)

    host.openSpaceFromSettings(requestedSpaceID)

    XCTAssertEqual(host.contexts.values.first?.store.session.selectedSpaceID, requestedSpaceID)
    XCTAssertFalse(window.wasOrdered)
  }
}

private final class SettingsWindowRuntime: ARCChromiumRuntime, @unchecked Sendable {
  private(set) var createdWindow: SettingsRecordingWindow?

  override func createWindowID(_ windowID: String) throws {
    MainActor.assumeIsolated {
      createdWindow = SettingsRecordingWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
        styleMask: [.borderless], backing: .buffered, defer: false)
    }
  }

  override func window(forID windowID: String) -> NSWindow? { createdWindow }
  override func hostView(forWindowID windowID: String) -> NSView? {
    MainActor.assumeIsolated { createdWindow?.contentView }
  }

  override func closeWindowID(_ windowID: String) -> Bool {
    MainActor.assumeIsolated {
      createdWindow?.close()
      createdWindow = nil
    }
    return true
  }
}

private final class SettingsRecordingWindow: NSWindow {
  private(set) var wasOrdered = false

  override func makeKeyAndOrderFront(_ sender: Any?) {
    wasOrdered = true
  }
}
