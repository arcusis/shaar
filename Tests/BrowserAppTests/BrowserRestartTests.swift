// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import XCTest

@testable import ArcusisBrowser

@MainActor
final class BrowserRestartTests: XCTestCase {
  func testRestartFlushesEveryWindowAndRestoresTabsWithStartFreshEnabled() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
    let workspace = try BrowserWorkspaceStore(file: file)
    let firstID = try XCTUnwrap(workspace.workspace.windows.first?.id)
    let secondID = try workspace.newWindow(from: firstID)
    let first = try XCTUnwrap(workspace.stores[firstID])
    let second = try XCTUnwrap(workspace.stores[secondID])
    first.perform(.open(try XCTUnwrap(URL(string: "https://example.test/first"))))
    second.perform(.open(try XCTUnwrap(URL(string: "https://example.test/second"))))
    let name = "BrowserRestartTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: "settingsStartFresh")
    let latestURL = try XCTUnwrap(URL(string: "https://example.test/latest"))
    var geometryFlushed = false
    try BrowserRestart.prepare(workspace: workspace, defaults: defaults) {
      geometryFlushed = true
      first.nativeTabChanged(
        first.session.selectedSpace.selectedTabID!,
        url: latestURL, title: "Latest title")
    }
    XCTAssertTrue(geometryFlushed)
    XCTAssertEqual(try BrowserWorkspaceStore(file: file).workspace, workspace.workspace)
    XCTAssertTrue(BrowserRestart.startsFresh(defaults: defaults, arguments: []))
    XCTAssertFalse(
      BrowserRestart.startsFresh(defaults: defaults, arguments: [BrowserRestart.restoreArgument]))
    XCTAssertTrue(defaults.bool(forKey: "settingsStartFresh"))
  }

  func testRestartRefusesUnwritableWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("not a directory".utf8).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = try BrowserWorkspaceStore(
      file: WorkspaceFile(
        url: directory.appending(path: "workspace.json"),
        legacySessionURL: directory.appending(path: "session.json")))
    XCTAssertThrowsError(try BrowserRestart.prepare(workspace: workspace, flushGeometry: {}))
  }
}
