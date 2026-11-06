// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsAccessibilityTests: XCTestCase {
  func testEverySectionExposesANameAndPanelNavigationHelp() {
    for section in ShaarDevToolsSection.allCases {
      XCTAssertFalse(ShaarDevToolsAccessibility.sectionLabel(section).isEmpty)
      XCTAssertTrue(
        ShaarDevToolsAccessibility.sectionHelp(section).contains("Left and Right Arrow"))
    }
  }

  func testArrowNavigationClampsAndHandlesEmptyControlGroups() {
    XCTAssertEqual(ShaarDevToolsNavigation.adjacentIndex(0, count: 3, forward: false), 0)
    XCTAssertEqual(ShaarDevToolsNavigation.adjacentIndex(2, count: 3, forward: true), 2)
    XCTAssertEqual(ShaarDevToolsNavigation.adjacentIndex(1, count: 3, forward: true), 2)
    XCTAssertNil(ShaarDevToolsNavigation.adjacentIndex(0, count: 0, forward: true))
  }

  func testReducedMotionDisablesShellAnimations() {
    var transaction = Transaction(animation: .easeInOut)
    ShaarDevToolsAccessibility.applyMotionPreference(to: &transaction, reduceMotion: true)
    XCTAssertNil(transaction.animation)
    XCTAssertTrue(transaction.disablesAnimations)
  }

  func testTooltipsNameTheDevToolsOpeningShortcuts() {
    XCTAssertTrue(ShaarDevToolsAccessibility.openHelp.contains("F12"))
    XCTAssertTrue(ShaarDevToolsAccessibility.openHelp.contains("Option-Command-I"))
    XCTAssertTrue(ShaarDevToolsAccessibility.closeHelp.contains("Escape"))
  }

  func testConsoleArrowNavigationSelectsAdjacentEntriesAndStopsAtEnds() {
    let model = ShaarConsoleModel()
    let first = ShaarConsoleRow(
      event: ShaarConsoleEvent(id: UUID(), level: .log, message: "first", source: nil), count: 1)
    let second = ShaarConsoleRow(
      event: ShaarConsoleEvent(id: UUID(), level: .log, message: "second", source: nil), count: 1)
    let rows = [first, second]

    model.selectAdjacent(in: rows, forward: true)
    XCTAssertEqual(model.selectedID, first.id)
    model.selectAdjacent(in: rows, forward: true)
    XCTAssertEqual(model.selectedID, second.id)
    model.selectAdjacent(in: rows, forward: true)
    XCTAssertEqual(model.selectedID, second.id)
    model.selectAdjacent(in: rows, forward: false)
    XCTAssertEqual(model.selectedID, first.id)
    model.selectAdjacent(in: rows, forward: true, from: second.id)
    XCTAssertEqual(model.selectedID, second.id)
  }

  func testAccessibilityStatesRenderOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_ACCESSIBILITY_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen accessibility capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previousKeyWindow = NSApp.keyWindow
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1242")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let warningID = UUID()
    let model = ShaarDevToolsModel(
      target: target,
      transport: ShaarDevToolsFixtureTransport(fixture: [
        .console(
          ShaarConsoleEvent(
            id: warningID, level: .warning, message: "Image response took 840 ms",
            source: "src/Dashboard.tsx", timestamp: Date(timeIntervalSince1970: 1))),
        .console(
          ShaarConsoleEvent(
            id: UUID(), level: .error, message: "Request failed: /api/summary",
            source: "src/api.ts", timestamp: Date(timeIntervalSince1970: 2))),
      ]))
    model.open(inspector: inspector)
    model.section = .console
    for _ in 0..<40 where model.events.count < 2 { await Task.yield() }
    XCTAssertTrue(model.streamAvailable)
    XCTAssertEqual(model.events.count, 2)
    model.console.selectedID = warningID

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let page = InspectorPageLayout(
        model: inspector, shell: model, openChromium: {}, page: { self.samplePage }
      )
      .frame(width: 1040, height: 680)
      .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        page, size: NSSize(width: 1040, height: 680), appearance: appearance,
        to: directory.appending(path: "after-\(suffix).png"))
    }
    model.close()
    XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
  }

  private var samplePage: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("localhost:3000/dashboard")
        .font(.system(size: 12, design: .monospaced))
      Divider()
      Text("Dashboard").font(.system(size: 24, weight: .semibold))
      Text("Inspect the local build while you work.")
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor))
  }
}
