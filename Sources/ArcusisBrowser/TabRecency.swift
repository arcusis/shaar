import Foundation

struct TabRecency {
  private var bySpace: [UUID: [UUID]] = [:]

  mutating func record(_ tab: UUID, in space: UUID) {
    var tabs = bySpace[space, default: []]
    tabs.removeAll { $0 == tab }
    tabs.insert(tab, at: 0)
    bySpace[space] = tabs
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
