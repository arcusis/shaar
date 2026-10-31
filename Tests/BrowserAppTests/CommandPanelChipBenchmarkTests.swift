// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser
@testable import BrowserCore

/// Switches Command-T chips in a hosted panel with a large library. The window is never ordered
/// on screen.
@MainActor
final class CommandPanelChipBenchmarkTests: XCTestCase {
  private static let historyCount = 5_000
  private static let bookmarkCount = 2_000

  func testChipSwitchReadsLauncherSourcesPerUpdateNotPerRow() throws {
    let fixture = try ChipFixture()
    defer { fixture.window.close() }
    fixture.warmUp()

    let switches = 20
    for _ in 0..<switches { fixture.switchChip() }

    // Each read rebuilds the sections key and asks the host for its Actions; rows used to read
    // the store themselves, about three host reads per row.
    let readsPerSwitch = Double(fixture.hostReads) / Double(switches)
    XCTAssertLessThan(readsPerSwitch, Double(CommandLauncher.filteredLimit) / 2)
  }

  func testChipSwitchingBenchmarkWhenRequested() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["COMMAND_PANEL_BENCHMARK"] == "1",
      "Set COMMAND_PANEL_BENCHMARK=1 to time chip switching")
    let fixture = try ChipFixture()
    defer { fixture.window.close() }
    fixture.warmUp()

    let switches = 100
    var samples: [Double] = []
    for _ in 0..<switches {
      let start = ContinuousClock.now
      fixture.switchChip()
      samples.append(milliseconds(start.duration(to: .now)))
    }
    samples.sort()
    let readsPerSwitch = Double(fixture.hostReads) / Double(switches)
    print(
      "COMMAND_PANEL_BENCHMARK history=\(Self.historyCount) bookmarks=\(Self.bookmarkCount) switches=\(switches) median_ms=\(samples[switches / 2]) p90_ms=\(samples[switches * 9 / 10]) max_ms=\(samples[switches - 1]) host_reads_per_switch=\(readsPerSwitch)"
    )
  }

  private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }

  /// A store with 40 tabs and a large library, its panel hosted the way the browser window
  /// hosts it, and a count of how often the panel asks the host for its Actions.
  @MainActor
  private final class ChipFixture {
    let store = BrowserStore()
    let window: NSWindow
    private(set) var hostReads = 0

    init() throws {
      for index in 0..<40 {
        store.perform(.open(URL(string: "https://tab-\(index).example/path")!))
      }
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      try loadLibrary()
      store.launcherActions = LauncherActions(
        available: { [unowned self] in
          hostReads += 1
          return LauncherCommands.catalog
        }, run: { _ in })
      store.showCommand()
      window.contentView = NSHostingView(
        rootView: CommandPanel(store: store, resultsHeight: 420)
          .frame(width: 640)
          .fixedSize(horizontal: false, vertical: true))
    }

    func warmUp() {
      for _ in 0...CommandFilter.allCases.count { switchChip() }
      hostReads = 0
    }

    func switchChip() {
      store.cycleCommandFilter(by: 1)
      RunLoop.main.run(until: .now)
      window.contentView?.layoutSubtreeIfNeeded()
      window.contentView?.displayIfNeeded()
    }

    private func loadLibrary() throws {
      let profile = store.session.selectedSpace.profileID
      let history = Self.historyRows(count: CommandPanelChipBenchmarkTests.historyCount)
      let bookmarks = Self.bookmarkTree(count: CommandPanelChipBenchmarkTests.bookmarkCount)
      store.library.onLoad = { key, _, done in
        switch key.section {
        case .history: done(.success(history))
        case .bookmarks: done(.success(bookmarks))
        }
      }
      store.library.refresh(profile, section: .history)
      store.library.refresh(profile, section: .bookmarks)
      XCTAssertEqual(
        store.library.history[profile]?.count, CommandPanelChipBenchmarkTests.historyCount)
      let bookmarkCount = try XCTUnwrap(store.library.bookmarks[profile]).items.count
      XCTAssertGreaterThanOrEqual(bookmarkCount, CommandPanelChipBenchmarkTests.bookmarkCount)
    }

    private static func historyRows(count: Int) -> [[String: Any]] {
      (0..<count).map(historyRow)
    }

    private static func historyRow(_ index: Int) -> [String: Any] {
      let url = "https://history-\(index).example/article/\(index)"
      let visitCount = NSNumber(value: index % 17 + 1)
      let visitTimes: [NSNumber] = [NSNumber(value: 1_700_000_000_000 + index)]
      return ["u": url, "t": "History page \(index)", "n": visitCount, "v": visitTimes]
    }

    private static func bookmarkRow(_ index: Int) -> [String: Any] {
      let url = "https://bookmark-\(index).example/"
      return ["id": UUID().uuidString, "k": "u", "t": "Bookmark \(index)", "u": url]
    }

    private static func bookmarkTree(count: Int) -> [String: Any] {
      let children: [[String: Any]] = (0..<count).map(bookmarkRow)
      return [
        "bar": [
          "id": "00000000-0000-4000-8000-000000000001", "k": "f", "t": "Bookmarks bar",
          "c": children,
        ],
        "other": [
          "id": "00000000-0000-4000-8000-000000000002", "k": "f", "t": "Other bookmarks",
          "c": [],
        ],
      ]
    }
  }
}
