// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct SidebarSplitIndexTests {
  @Test func splitAndTabLookupsPreserveFirstMatchBehavior() {
    let tabs = (1...4).map { tab($0) }
    let first = BrowserSplit(tabIDs: [tabs[1].id, tabs[0].id])
    let overlapping = BrowserSplit(tabIDs: [tabs[1].id, tabs[2].id])
    let index = SidebarTabIndex(tabs: tabs, splits: [first, overlapping])

    #expect(index.isSplitRowLeader(tabs[1].id))
    #expect(!index.isSplitRowLeader(tabs[0].id))
    #expect(!index.isSplitRowLeader(tabs[2].id))
    #expect(index.isSplitRowLeader(tabs[3].id))
    #expect(index.split(ledBy: tabs[1].id) == first)
    #expect(index.tab(for: tabs[0].id) == tabs[0])
    #expect(index.tab(for: uuid(99)) == nil)
  }

  @Test func sidebarSplitMembershipScanFocusedBenchmark() {
    let (tabs, splits) = makeFixture(tabCount: 1_000)
    let iterations = 3
    let beforeStart = ContinuousClock.now
    var beforeLeaders = 0
    for _ in 0..<iterations {
      for tab in tabs {
        if splits.first(where: { $0.tabIDs.contains(tab.id) })?.tabIDs.first == tab.id {
          beforeLeaders += 1
        }
      }
    }
    let before = beforeStart.duration(to: .now)

    let afterStart = ContinuousClock.now
    var afterLeaders = 0
    for _ in 0..<iterations {
      let index = SidebarTabIndex(tabs: tabs, splits: splits)
      for tab in tabs where index.isSplitRowLeader(tab.id) { afterLeaders += 1 }
    }
    let after = afterStart.duration(to: .now)
    print("sidebarSplitMembershipBenchmark: before=\(before), after=\(after)")
    #expect(beforeLeaders == 500 * iterations && afterLeaders == beforeLeaders)
  }

  private func makeFixture(tabCount: Int) -> ([BrowserTab], [BrowserSplit]) {
    let tabs = (0..<tabCount).map { index in
      BrowserTab(
        id: uuid(index + 1), url: URL(string: "https://example.com/\(index)")!,
        isPinned: index.isMultiple(of: 2))
    }
    let splits = stride(from: 0, to: tabCount, by: 2).map { index in
      BrowserSplit(tabIDs: [tabs[index].id, tabs[index + 1].id])
    }
    return (tabs, splits)
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
  }

  private func tab(_ number: Int) -> BrowserTab {
    BrowserTab(
      id: uuid(number), url: URL(string: "https://example.com/\(number)")!)
  }
}
