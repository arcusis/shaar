// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test func leavingAnOverlappedPointerTargetPreservesTheNewTarget() {
  let previous: String? = "old"
  #expect(previous.updatingTarget("new", isActive: false) == "old")
  #expect(previous.updatingTarget("old", isActive: false) == nil)
  #expect(previous.updatingTarget("new", isActive: true) == "new")
}

@Test func insertionAnchorTracksOneStepMovesAndEndPosition() {
  let items = [PointerTargetTestItem(id: "a"), .init(id: "b"), .init(id: "c"), .init(id: "d")]

  #expect(items.insertionAnchor(movingIndex: 2, by: -1) == "b")
  #expect(items.insertionAnchor(movingIndex: 0, by: 1) == "c")
  #expect(items.insertionAnchor(movingIndex: 2, by: 1) == nil)
}

@Test func insertionAnchorRejectsInvalidMovesAndBoundaryIndexes() {
  let items = [PointerTargetTestItem(id: "a"), .init(id: "b")]
  let empty: [PointerTargetTestItem] = []

  #expect(empty.insertionAnchor(movingIndex: 0, by: -1) == nil)
  #expect(items.insertionAnchor(movingIndex: 0, by: -1) == nil)
  #expect(items.insertionAnchor(movingIndex: 1, by: 1) == nil)
  #expect(items.insertionAnchor(movingIndex: -1, by: 1) == nil)
  #expect(items.insertionAnchor(movingIndex: 0, by: 0) == nil)
}

private struct PointerTargetTestItem: Identifiable {
  let id: String
}
