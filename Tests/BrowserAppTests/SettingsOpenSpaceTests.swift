// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
}
