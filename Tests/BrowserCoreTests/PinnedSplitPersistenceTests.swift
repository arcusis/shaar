// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Suite
struct PinnedSplitPersistenceTests {
  private func fixture() -> (BrowserSession, [UUID]) {
    var session = BrowserSession.fresh()
    let ids = (0..<4).map { session.open(URL(string: "https://tab\($0).example")!)! }
    for id in ids.prefix(3) { session.togglePin(id) }
    session.splitTabs(ids[0], ids[1], in: session.selectedSpaceID)
    session.addToSplit(ids[2], beside: ids[1], edge: .bottom, in: session.selectedSpaceID)
    return (session, ids)
  }

  @Test func catalogRestoresWeightedPinnedStackWithFreshPageIDsAfterLastWindowCloses() throws {
    var (session, ids) = fixture()
    let space = session.selectedSpaceID
    let split = try #require(session.selectedSpace.splits.first)
    session.setSplitWeights([0.3, 0.7], at: [], splitID: split.id, in: space)
    let layout = try #require(session.selectedSpace.splits.first?.root)
    var workspace = try BrowserWorkspace(session: session)
    let first = workspace.windows[0].id
    let second = try workspace.addWindow(from: first)
    let reopened = try #require(workspace.window(second)?.session.selectedSpace.splits.first)
    #expect(reopened.tabIDs.count == 3)
    #expect(Set(reopened.tabIDs).isDisjoint(with: ids))
    #expect(workspace.catalog.spaces.first { $0.id == space }?.splits.first?.root == layout)
    // A divider update must travel through definition IDs, not leak live page IDs.
    var changed = try #require(workspace.window(second)?.session)
    changed.setSplitWeights([0.6, 0.4], at: [], splitID: reopened.id, in: space)
    try workspace.updateWindow(second, session: changed)
    try workspace.removeWindow(first)
    try workspace.removeWindow(second)
    let bytes = try JSONEncoder().encode(workspace)
    workspace = try JSONDecoder().decode(BrowserWorkspace.self, from: bytes)
    let next = try workspace.addWindow()
    let restored = try #require(workspace.window(next)?.session.selectedSpace.splits.first)
    #expect(restored.tabIDs.count == 3)
    #expect(restored.id == split.id)
    if case .group(_, _, let weights) = restored.root {
      #expect(weights == [0.6, 0.4])
    } else {
      Issue.record("Weighted stack was flattened")
    }
    try workspace.validate()
  }

  @Test func ordinarySplitsRemainWindowLocalAndRemovingPinnedStackPropagates() throws {
    var (session, ids) = fixture()
    let space = session.selectedSpaceID
    let another = session.open(URL(string: "https://ordinary.example")!)!
    session.splitTabs(ids[3], another, in: space)
    var workspace = try BrowserWorkspace(session: session)
    let first = workspace.windows[0].id
    let second = try workspace.addWindow(from: first)
    #expect(workspace.window(second)?.session.selectedSpace.splits.count == 1)
    session.unsplitTab(ids[0], in: space)
    session.unsplitTab(ids[1], in: space)
    try workspace.updateWindow(first, session: session)
    #expect(workspace.window(second)?.session.selectedSpace.splits.isEmpty == true)
    #expect(workspace.window(first)?.session.selectedSpace.splits.count == 1)
    try workspace.validate()
  }

  @Test func stackAndContainingFolderCanMoveAcrossSharedSpacesWithoutFlattening() throws {
    var (session, ids) = fixture()
    let source = session.selectedSpaceID
    let folder = session.addFolder(name: "Projects", in: source)!
    let split = try #require(session.selectedSpace.splits.first)
    #expect({ session.moveSplit(split.id, from: source, to: source, folderID: folder) }())
    let target = session.addSpace(name: "Shared", sharingProfile: session.selectedSpace.profileID)!
    #expect({ session.moveFolder(folder, from: source, to: target, pinned: false) }())
    let moved = try #require(session.spaces.first { $0.id == target })
    #expect(moved.splits == [split])
    #expect(moved.tabs.map(\.id) == Array(ids.prefix(3)))
    #expect(moved.tabs.allSatisfy { !$0.isPinned && $0.folderID == folder })
    #expect(
      { session.moveSplit(split.id, from: target, to: source, before: ids[3], pinned: false) }())
    #expect(session.spaces.first { $0.id == source }?.splits == [split])
    #expect(session.spaces.first { $0.id == target }?.splits.isEmpty == true)
    try session.validate()
  }

  @Test func refusedStackMovesAreAtomicAndJoiningAdoptsTargetSection() throws {
    var (session, ids) = fixture()
    let source = session.selectedSpaceID
    let split = try #require(session.selectedSpace.splits.first)
    let before = session
    #expect({ !session.moveSplit(split.id, from: source, to: session.spaces[1].id) }())
    #expect({ !session.moveSplit(split.id, from: source, to: source, before: ids[1]) }())
    #expect({ !session.moveSplit(split.id, from: source, to: source, folderID: UUID()) }())
    #expect({ !session.moveSplit(split.id, from: source, to: source, before: UUID()) }())
    #expect(session == before)
    #expect({ session.addToSplit(ids[3], beside: ids[0], edge: .right, in: source) }())
    #expect(session.selectedSpace.tabs.allSatisfy { $0.isPinned })
    #expect(session.selectedSpace.splits.first?.tabIDs.count == BrowserSplit.maxPanes)
    try session.validate()
  }

  @Test func refusedFolderSectionChangesPreserveNestedStackAndOrder() throws {
    var (session, _) = fixture()
    let space = session.selectedSpaceID
    let folder = session.addFolder(name: "Projects", in: space)!
    let child = session.addFolder(name: "Nested", in: space, parentID: folder)!
    let today = session.addFolder(name: "Reading", in: space, section: .today)!
    let split = try #require(session.selectedSpace.splits.first)
    let grouped = session.moveSplit(split.id, from: space, to: space, folderID: child)
    #expect(grouped)
    let before = session
    let wrongSiblingSection = session.moveFolder(
      folder, from: space, to: space, before: today, pinned: true)
    #expect(!wrongSiblingSection)
    #expect(session == before)
    let wrongParentSection = session.moveFolder(
      folder, from: space, to: space, parentID: today, pinned: true)
    #expect(!wrongParentSection)
    #expect(session == before)
    try session.validate()
  }

  @Test func regroupingMemberKeepsBothStacksValidAndAdoptsDestinationSection() throws {
    var (session, ids) = fixture()
    let space = session.selectedSpaceID
    let regrouped = session.addToSplit(ids[1], beside: ids[3], edge: .right, in: space)
    #expect(regrouped)
    #expect(session.selectedSpace.splits.count == 2)
    #expect(
      session.selectedSpace.splits.first { $0.tabIDs.contains(ids[0]) }?.tabIDs == [ids[0], ids[2]])
    #expect(
      session.selectedSpace.splits.first { $0.tabIDs.contains(ids[3]) }?.tabIDs == [ids[3], ids[1]])
    #expect(session.selectedSpace.tabs.first { $0.id == ids[1] }?.isPinned == false)
    let reordered = session.addToSplit(ids[1], beside: ids[3], edge: .left, in: space)
    #expect(reordered)
    #expect(
      session.selectedSpace.splits.first { $0.tabIDs.contains(ids[3]) }?.tabIDs == [ids[1], ids[3]])
    #expect(session.selectedSpace.tabs.filter { $0.isPinned }.map(\.id) == [ids[0], ids[2]])
    try session.validate()
  }

}
