// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Darwin
import Foundation
import XCTest

@testable import ArcusisBrowser

@MainActor
final class BrowserRestartTests: XCTestCase {
  func testRelaunchWithoutAnExecutableFailsWithoutReplacingTestProcess() {
    XCTAssertThrowsError(try BrowserRestart.relaunch(executable: nil)) { error in
      XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
    }
  }

  func testRelaunchReportsExecFailureForMissingExecutableWithUnicodePath() {
    let missing = FileManager.default.temporaryDirectory
      .appending(path: "Shaar-בדיקה-\(UUID().uuidString)/Shaar")
    XCTAssertThrowsError(try BrowserRestart.relaunch(executable: missing)) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .ENOENT)
    }
  }

  func testRelaunchPreservesUnicodeExecutablePathWhenCallingExec() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "Shaar-בדיקה-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "שער")
    try Data("not executable".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
    XCTAssertThrowsError(try BrowserRestart.relaunch(executable: executable)) { error in
      XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
    }
  }

  func testPendingLanguageRestartRendersInHiddenSettingsWindow() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let keyWindow = NSApp.keyWindow
    let defaults = UserDefaults.standard
    let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
    let pending: BrowserLanguage = BrowserLanguage.launchSelection == .hebrew ? .english : .hebrew
    var arguments = original
    arguments[BrowserLanguage.selectionDefaultsKey] = pending.rawValue
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    let workspace = try BrowserWorkspaceStore()
    let controller = BrowserSettingsController(
      workspace: workspace, preferences: BrowserPreferencesStore(), presentation: .hiddenProbe)
    var restartCalls = 0
    controller.setRestartHandler {
      restartCalls += 1
      return nil
    }
    controller.show()
    defer { controller.close() }
    let window = try XCTUnwrap(controller.window)
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let directory = URL(filePath: "build/Verification/language-restart-settings")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bitmap = try VisualCapture.render(content, to: directory.appending(path: "pending.png"))
    XCTAssertEqual(bitmap.pixelsWide, Int(content.bounds.width))
    XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    XCTAssertFalse(window.isVisible)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    XCTAssertEqual(restartCalls, 0, "Rendering the prompt must not request a restart.")
    XCTAssertEqual(workspace.workspace.windows.count, 1)
  }

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
