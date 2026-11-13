// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct TabRecency {
  private var bySpace: [UUID: [UUID]] = [:]

  mutating func record(_ tab: UUID, in space: UUID) {
    var tabs = bySpace[space, default: []]
    tabs.removeAll { $0 == tab }
    tabs.insert(tab, at: 0)
    bySpace[space] = tabs
  }

  @discardableResult
  mutating func reconcile(availableBySpace: [UUID: [UUID]]) -> Int {
    var removed = 0
    var retained: [UUID: [UUID]] = [:]
    for (space, available) in availableBySpace {
      let availableIDs = Set(available)
      let tabs = (bySpace[space] ?? []).filter { availableIDs.contains($0) }
      removed += (bySpace[space]?.count ?? 0) - tabs.count
      if !tabs.isEmpty { retained[space] = tabs }
    }
    removed += bySpace.filter { availableBySpace[$0.key] == nil }
      .reduce(0) { $0 + $1.value.count }
    bySpace = retained
    return removed
  }

  func ordered(in space: UUID, available: [UUID]) -> [UUID] {
    let valid = Set(available)
    let recent = (bySpace[space] ?? []).filter { valid.contains($0) }
    let seen = Set(recent)
    return recent + available.filter { !seen.contains($0) }
  }

  static func cycle(_ index: Int, count: Int, reverse: Bool) -> Int {
    guard count > 0 else { return 0 }
    return (index + (reverse ? count - 1 : 1)) % count
  }
}
