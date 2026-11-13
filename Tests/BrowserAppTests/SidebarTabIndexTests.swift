// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct SidebarTabIndexTests {
  @Test func dropSlotsStayWithinTargetGroupAndSkipMovingTab() {
    let folder = uuid(100)
    let index = SidebarTabIndex(tabs: [
      tab(1, pinned: true, folderID: folder), tab(2),
      tab(3, pinned: true, folderID: folder), tab(4, pinned: true),
      tab(5, pinned: true, folderID: folder),
    ])
    #expect(index.dropSlot(targetID: uuid(1), sourceID: uuid(5), after: false) == .before(uuid(1)))
    #expect(index.dropSlot(targetID: uuid(1), sourceID: uuid(3), after: true) == .before(uuid(5)))
    #expect(index.dropSlot(targetID: uuid(3), sourceID: uuid(5), after: true) == .end)
    #expect(index.dropSlot(targetID: uuid(2), sourceID: uuid(1), after: true) == .end)
    #expect(index.dropSlot(targetID: uuid(1), sourceID: uuid(1), after: false) == nil)
    #expect(index.dropSlot(targetID: uuid(99), sourceID: uuid(1), after: true) == nil)
  }

  @Test func splitMenuCandidatesPreserveOrderAndOmitTheSelectedTab() {
    let tabs = [tab(1), tab(2), tab(3)]
    let middle = SidebarSplitMenuCandidateRanges(tabs: tabs, excluding: uuid(2))
    #expect((Array(middle.before) + Array(middle.after)).map { tabs[$0].id } == [uuid(1), uuid(3)])
    let unknown = SidebarSplitMenuCandidateRanges(tabs: tabs, excluding: uuid(99))
    #expect((Array(unknown.before) + Array(unknown.after)).map { tabs[$0].id } == tabs.map(\.id))
    let singleton = SidebarSplitMenuCandidateRanges(tabs: [tabs[1]], excluding: tabs[1].id)
    #expect(singleton.before.isEmpty && singleton.after.isEmpty)
  }

  @Test func mixedGroupsKeepOriginalSiblingOrderAndEdges() {
    let folderA = uuid(100)
    let folderB = uuid(101)
    let tabs = [
      tab(1, pinned: true, folderID: folderA),
      tab(2),
      tab(3, pinned: true, folderID: folderB),
      tab(4, pinned: true, folderID: folderA),
      tab(5, pinned: true),
      tab(6),
      tab(7, pinned: true, folderID: folderA),
      tab(8, pinned: true, folderID: folderB),
    ]
    let index = SidebarTabIndex(tabs: tabs)

    #expect(index.boundary(for: uuid(1)) == .init(isFirst: true, isLast: false))
    #expect(index.boundary(for: uuid(4)) == .init(isFirst: false, isLast: false))
    #expect(index.boundary(for: uuid(7)) == .init(isFirst: false, isLast: true))
    #expect(index.boundary(for: uuid(3)) == .init(isFirst: true, isLast: false))
    #expect(index.boundary(for: uuid(8)) == .init(isFirst: false, isLast: true))
    #expect(index.boundary(for: uuid(5)) == .init(isFirst: true, isLast: true))
    #expect(index.boundary(for: uuid(2)) == .init(isFirst: true, isLast: false))
    #expect(index.boundary(for: uuid(6)) == .init(isFirst: false, isLast: true))
  }

  @Test func emptySingletonAndUnknownRowsAreConservative() {
    let empty = SidebarTabIndex(tabs: [])
    #expect(empty.boundary(for: uuid(99)) == .init(isFirst: true, isLast: true))

    let singleton = SidebarTabIndex(tabs: [tab(1)])
    #expect(singleton.boundary(for: uuid(1)) == .init(isFirst: true, isLast: true))
    #expect(singleton.boundary(for: uuid(2)) == .init(isFirst: true, isLast: true))
  }

  @Test func reorderedAndNewSnapshotsBuildFreshBoundaries() {
    let original = SidebarTabIndex(tabs: [tab(1), tab(2), tab(3)])
    #expect(original.boundary(for: uuid(1)) == .init(isFirst: true, isLast: false))
    #expect(original.boundary(for: uuid(3)) == .init(isFirst: false, isLast: true))

    let updated = SidebarTabIndex(tabs: [tab(3), tab(1), tab(4)])
    #expect(updated.boundary(for: uuid(3)) == .init(isFirst: true, isLast: false))
    #expect(updated.boundary(for: uuid(1)) == .init(isFirst: false, isLast: false))
    #expect(updated.boundary(for: uuid(4)) == .init(isFirst: false, isLast: true))
    #expect(updated.boundary(for: uuid(2)) == .init(isFirst: true, isLast: true))
    #expect(original.boundary(for: uuid(1)) == .init(isFirst: true, isLast: false))
  }

  @Test func largeAuthoredSnapshotHasExpectedEdgesForEveryTab() {
    struct ExpectedGroup: Hashable {
      let pinned: Bool
      let folder: Int?
    }

    let groups = (0..<13).map { slot in
      ExpectedGroup(pinned: slot < 9, folder: slot < 9 ? slot : nil)
    }
    var expectedEnds: [ExpectedGroup: (first: UUID, last: UUID)] = [:]
    let tabs = (0..<2048).map { offset -> BrowserTab in
      let id = uuid(offset + 1)
      let group = groups[(offset * 7 + offset / 13) % groups.count]
      let folderID = group.folder.map { uuid(10_000 + $0) }
      if let first = expectedEnds[group]?.first {
        expectedEnds[group] = (first, id)
      } else {
        expectedEnds[group] = (id, id)
      }
      return BrowserTab(
        id: id, url: URL(string: "https://example.com/\(offset)")!, isPinned: group.pinned,
        folderID: folderID)
    }
    let index = SidebarTabIndex(tabs: tabs)

    for (offset, tab) in tabs.enumerated() {
      let group = groups[(offset * 7 + offset / 13) % groups.count]
      let ends = expectedEnds[group]!
      #expect(
        index.boundary(for: tab.id)
          == .init(isFirst: tab.id == ends.first, isLast: tab.id == ends.last))
    }
  }

  @Test func dropSlotLookupAvoidsPerTargetSiblingMaterialization() {
    let tabs = (0..<1_000).map { offset in
      tab(offset + 1, pinned: true, folderID: uuid(10_000 + offset / 50))
    }
    let targets = stride(from: 0, to: tabs.count, by: 2).map { tabs[$0] }
    let index = SidebarTabIndex(tabs: tabs)
    let iterations = 3

    let beforeStart = ContinuousClock.now
    var beforeSlots: [SidebarTabIndex.DropSlot?] = []
    for _ in 0..<iterations {
      for target in targets {
        beforeSlots.append(
          legacyDropSlot(tabs: tabs, targetID: target.id, sourceID: tabs.last!.id, after: true))
      }
    }
    let before = beforeStart.duration(to: .now)

    let afterStart = ContinuousClock.now
    var afterSlots: [SidebarTabIndex.DropSlot?] = []
    for _ in 0..<iterations {
      for target in targets {
        afterSlots.append(
          index.dropSlot(targetID: target.id, sourceID: tabs.last!.id, after: true))
      }
    }
    let after = afterStart.duration(to: .now)

    #expect(beforeSlots == afterSlots)
    #expect(seconds(after) < seconds(before) * 0.5)
    print("sidebarDropSlotFocusedBenchmark: before=\(before), after=\(after)")
  }

  private func legacyDropSlot(
    tabs: [BrowserTab], targetID: UUID, sourceID: UUID, after: Bool
  ) -> SidebarTabIndex.DropSlot? {
    guard targetID != sourceID, let target = tabs.first(where: { $0.id == targetID }) else {
      return nil
    }
    guard after else { return .before(targetID) }
    let siblings = tabs.filter {
      $0.id != sourceID && $0.isPinned == target.isPinned && $0.folderID == target.folderID
    }
    guard let position = siblings.firstIndex(where: { $0.id == targetID }) else { return nil }
    let next = siblings.index(after: position)
    return next < siblings.endIndex ? .before(siblings[next].id) : .end
  }

  private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  @Test func sidebarSplitMenuCandidateFilteringFocusedBenchmark() {
    let tabs = (0..<1_000).map { offset in
      tab(offset + 1)
    }
    var candidateCount = 0
    let start = ContinuousClock.now
    for _ in 0..<3 {
      for selected in tabs {
        for candidate in tabs.filter({ $0.id != selected.id }) {
          candidateCount += candidate.title.isEmpty ? 0 : 1
        }
      }
    }
    print("sidebarSplitMenuCandidateFilteringFocusedBenchmark: \(start.duration(to: .now))")
    #expect(candidateCount == 2_997_000)

    var indexedCandidateCount = 0
    let indexedStart = ContinuousClock.now
    for _ in 0..<3 {
      for selected in tabs {
        let ranges = SidebarSplitMenuCandidateRanges(tabs: tabs, excluding: selected.id)
        for index in ranges.before {
          indexedCandidateCount += tabs[index].title.isEmpty ? 0 : 1
        }
        for index in ranges.after {
          indexedCandidateCount += tabs[index].title.isEmpty ? 0 : 1
        }
      }
    }
    print("sidebarSplitMenuCandidateRangeFocusedBenchmark: \(indexedStart.duration(to: .now))")
    #expect(indexedCandidateCount == candidateCount)
  }

  private func tab(_ number: Int, pinned: Bool = false, folderID: UUID? = nil) -> BrowserTab {
    BrowserTab(
      id: uuid(number), url: URL(string: "https://example.com/\(number)")!, isPinned: pinned,
      folderID: folderID)
  }

  private func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", number))!
  }
}
