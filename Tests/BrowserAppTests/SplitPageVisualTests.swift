// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class SplitPageVisualTests: XCTestCase {
  func testSplitLayoutMenuValueIncludesArrangementAndPaneCount() {
    let value = SplitLayoutControls.accessibilityValue(preset: .rows, paneCount: 3)
    XCTAssertTrue(value.contains(SplitLayoutPreset.rows.title))
    XCTAssertTrue(value.contains(ShellL10n.plural("%d tabs", count: 3)))
  }

  func testSplitDividerHighlightAnimationRespectsReduceMotion() {
    XCTAssertNil(SplitGroupView.dividerHighlightAnimation(reduceMotion: true))
    XCTAssertNotNil(SplitGroupView.dividerHighlightAnimation(reduceMotion: false))
  }

  func testSplitDividerLabelsIncludeOrientationAndPosition() {
    XCTAssertEqual(
      SplitDividerAccessibility.label(
        axis: .columns, index: 1, dividerCount: 2, language: .english),
      "Vertical split divider 2 of 2")
    XCTAssertEqual(
      SplitDividerAccessibility.label(
        axis: .rows, index: 0, dividerCount: 1, language: .english),
      "Horizontal split divider 1 of 1")
    XCTAssertEqual(
      SplitDividerAccessibility.label(
        axis: .columns, index: 0, dividerCount: 1, language: .hebrew),
      "מפריד אנכי בתצוגה מפוצלת, 1 מתוך 1")
  }

  func testSplitDividerKeyboardInputRespectsAxisAndDirection() {
    XCTAssertEqual(
      SplitDividerInput.keyboardDelta(for: .left, axis: .columns, isRightToLeft: false, step: 32),
      -32)
    XCTAssertEqual(
      SplitDividerInput.keyboardDelta(for: .right, axis: .columns, isRightToLeft: false, step: 32),
      32)
    XCTAssertEqual(
      SplitDividerInput.keyboardDelta(for: .left, axis: .columns, isRightToLeft: true, step: 32),
      32)
    XCTAssertEqual(
      SplitDividerInput.keyboardDelta(for: .right, axis: .columns, isRightToLeft: true, step: 32),
      -32)
    XCTAssertEqual(
      SplitDividerInput.keyboardDelta(for: .up, axis: .rows, isRightToLeft: false, step: 32), -32)
    XCTAssertEqual(
      SplitDividerInput.keyboardDelta(for: .down, axis: .rows, isRightToLeft: false, step: 32), 32)
    XCTAssertNil(
      SplitDividerInput.keyboardDelta(for: .up, axis: .columns, isRightToLeft: false, step: 32))
    XCTAssertNil(
      SplitDividerInput.keyboardDelta(for: .left, axis: .rows, isRightToLeft: false, step: 32))
    XCTAssertEqual(
      SplitDividerInput.accessibilityDelta(for: .increment, step: 32), 32)
    XCTAssertEqual(
      SplitDividerInput.accessibilityDelta(for: .decrement, step: 32), -32)
  }

  func testSplitDividerActionsApplyKeyboardAndAccessibilityChanges() {
    var changes: [CGFloat] = []
    let right = SplitDividerInput.keyboardAction(
      for: .right, axis: .columns, isRightToLeft: false, step: 32
    ) { changes.append($0) }
    XCTAssertEqual(right(), .handled)
    XCTAssertEqual(changes, [32])

    let leftToRight = SplitDividerInput.keyboardAction(
      for: .left, axis: .columns, isRightToLeft: true, step: 32
    ) { changes.append($0) }
    XCTAssertEqual(leftToRight(), .handled)
    XCTAssertEqual(changes, [32, 32])

    let wrongAxis = SplitDividerInput.keyboardAction(
      for: .up, axis: .columns, isRightToLeft: false, step: 32
    ) { changes.append($0) }
    XCTAssertEqual(wrongAxis(), .ignored)
    XCTAssertEqual(changes, [32, 32])

    let adjust = SplitDividerInput.accessibilityAction(step: 32) { changes.append($0) }
    adjust(.increment)
    adjust(.decrement)
    XCTAssertEqual(changes, [32, 32, 32, -32])
  }

  func testSplitDividerResizeKeepsBothPanesAboveMinimum() {
    let initial = [0.5, 0.5]
    XCTAssertEqual(SplitGroupView.resized(initial, at: 0, by: 40, available: 400), [0.6, 0.4])
    XCTAssertEqual(SplitGroupView.resized(initial, at: 0, by: 400, available: 400), [0.6, 0.4])
    XCTAssertEqual(SplitGroupView.resized(initial, at: 2, by: 40, available: 400), initial)
    XCTAssertEqual(SplitGroupView.resized(initial, at: .max, by: 40, available: 400), initial)
    XCTAssertEqual(SplitGroupView.resized(initial, at: 0, by: 40, available: 0), initial)
  }

  func testStaleDragWeightsDoNotOutnumberUpdatedChildren() {
    XCTAssertEqual(
      SplitGroupView.displayedWeights([0.4, 0.3, 0.3], matching: [0.5, 0.5]), [0.5, 0.5])
    XCTAssertEqual(
      SplitGroupView.displayedWeights([0.6, 0.4], matching: [0.5, 0.5]), [0.6, 0.4])
  }

  func testSplitDividerViewBuildsInHeadlessHost() {
    let ids = [UUID(), UUID()]
    let view = SplitPageView(
      split: BrowserSplit(tabIDs: ids), focusedID: ids[0], onFocus: { _ in },
      onWeightsChange: { _, _ in }, header: { _ in Text("Pane header") },
      pane: { _ in Text("Pane content") })
    let host = NSHostingView(rootView: view.frame(width: 500, height: 300))
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
    host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(host.fittingSize.width, 0)
  }

  func testMixedLayoutCapture() async throws {
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled, "Visual capture requires explicit opt-in")
    var session = BrowserSession.fresh()
    let hosts = ["first.example", "second.example", "third.example"]
    let ids = try hosts.map { try XCTUnwrap(session.open(URL(string: "https://\($0)")!)) }
    let space = session.selectedSpaceID
    XCTAssertTrue(session.splitTabs(ids[0], ids[1], in: space))
    XCTAssertTrue(session.addToSplit(ids[2], beside: ids[1], edge: .bottom, in: space))
    let store = BrowserStore(session: session)
    let split = try XCTUnwrap(store.selectedSplit)
    let colors = [
      Color(red: 0.90, green: 0.94, blue: 0.99), Color(red: 0.96, green: 0.92, blue: 0.86),
      Color(red: 0.90, green: 0.97, blue: 0.91),
    ]
    let panes = SplitPageView(
      split: split, focusedID: store.session.selectedSpace.selectedTabID,
      onFocus: { _ in }, onWeightsChange: { _, _ in },
      header: { id in SplitPaneToolbar(store: store, tabID: id) },
      pane: { id in
        let index = ids.firstIndex(of: id) ?? 0
        ZStack {
          colors[index]
          Text("Page \(index + 1)").foregroundStyle(.black)
        }
      })
    let root = try SidebarVisualCaptureSupport.prepare()
    let size = NSSize(width: 900, height: 560)
    let before = VStack(spacing: 0) {
      HStack {
        PageNavigationButtons(store: store, engine: nil)
        SplitLayoutControls(store: store, split: split)
        Spacer()
      }
      .frame(height: 34)
      panes
    }
    let beforeMount = try MountedChromeSidebar(
      view: before, size: size, appearance: .aqua)
    defer { beforeMount.close() }
    _ = try await beforeMount.capture(
      to: root.appendingPathComponent("split-pane-navigation-before.png"),
      requiredText: ["Page 1", "Page 2", "Page 3"])

    let after = VStack(spacing: 0) {
      BrowserChromeSurface(store: store, engine: nil)
      panes
    }
    let afterMount = try MountedChromeSidebar(
      view: after, size: size, appearance: .aqua)
    defer { afterMount.close() }
    _ = try await afterMount.capture(
      to: root.appendingPathComponent("split-pane-navigation.png"),
      requiredText: ["Page 1", "Page 2", "Page 3"])
  }

  func testSidebarSplitRowCapture() async throws {
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled, "Visual capture requires explicit opt-in")
    let segments = ["Jira Board", "Google", "Naza"].map {
      SidebarSplitRow.Segment(id: UUID(), title: $0, favicon: nil)
    }
    let view = SidebarSplitRow(
      segments: segments, focusedID: segments[1].id, isSelected: true,
      onSelect: { _ in }, onClose: { _ in },
      onDrag: { .tab(sessionID: UUID(), sourceSpaceID: UUID(), tabID: $0) }
    )
    .padding(.horizontal, 12)
    .frame(width: 260, height: 90)
    .background(Color(red: 0.12, green: 0.12, blue: 0.13))
    let mounted = try MountedChromeSidebar(
      view: view, size: NSSize(width: 260, height: 90), appearance: .darkAqua)
    defer { mounted.close() }
    _ = try await mounted.capture(
      to: URL(fileURLWithPath: "/tmp/split-sidebar-row.png"), requiredText: [])
  }
}
