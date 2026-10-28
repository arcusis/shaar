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

  private func tab(_ number: Int, pinned: Bool = false, folderID: UUID? = nil) -> BrowserTab {
    BrowserTab(
      id: uuid(number), url: URL(string: "https://example.com/\(number)")!, isPinned: pinned,
      folderID: folderID)
  }

  private func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", number))!
  }
}
