import BrowserCore
import Foundation
import Testing

@Test func bookmarkTreePreservesHierarchyAndUnsupportedAddressesWithoutExecutingThem() throws {
  let profile = UUID()
  let folder = UUID()
  let page = UUID()
  let script = UUID()
  let payload = bookmarkPayload(children: [
    [
      "id": folder.uuidString, "k": "f", "t": "Company",
      "c": [
        ["id": page.uuidString, "k": "u", "t": "Console", "u": "https://example.com/console"],
        ["id": script.uuidString, "k": "u", "t": "Legacy bookmarklet", "u": "javascript:alert(1)"],
      ],
    ]
  ])
  let tree = try BookmarkTree(profileID: profile, payload: payload)
  #expect(tree.items.count == 5)
  #expect(tree.items.allSatisfy { $0.profileID == profile })
  #expect(tree.items.filter(\.isPermanent).map(\.id) == [tree.barID, tree.otherID])
  let item = try #require(tree.items.first { $0.id == page })
  #expect(item.parentID == folder && item.depth == 2 && item.path.contains("Company / Console"))
  #expect(tree.contains(folder, inPathTo: page))
  #expect(!tree.contains(page, inPathTo: folder))
  let legacy = try #require(tree.items.first { $0.id == script })
  #expect(!legacy.isFolder && legacy.address != nil && legacy.destination == nil)
}

@Test func malformedBookmarkTreesRejectDuplicateIDsAndInvalidShapes() throws {
  let id = UUID().uuidString
  for children in [
    [["id": id, "k": "f", "t": "Missing children"]],
    [["id": id, "k": "x", "t": "Unknown"]],
    [["id": id, "k": "u", "t": "Missing URL"]],
    [["id": id, "k": "u", "t": "Bad URL", "u": "not a url"]],
    [["id": id, "k": "f", "t": "A", "c": []], ["id": id, "k": "f", "t": "B", "c": []]],
  ] as [[[String: Any]]] {
    #expect(throws: LibraryDataError.self) {
      try BookmarkTree(profileID: UUID(), payload: bookmarkPayload(children: children))
    }
  }
  var deep: [String: Any] = ["id": UUID().uuidString, "k": "f", "t": "Leaf", "c": []]
  for index in 0..<300 {
    deep = ["id": UUID().uuidString, "k": "f", "t": "Level \(index)", "c": [deep]]
  }
  #expect(
    try BookmarkTree(profileID: UUID(), payload: bookmarkPayload(children: [deep])).items.count
      == 303)
}

@Test func historyDatesCountsAndAddressesAreValidatedBeforeDisplay() throws {
  let profile = UUID()
  let wire: [String: Any] = [
    "u": "https://example.com/account", "t": "", "n": 3, "v": [1000.0, 2000.0],
  ]
  let entry = try BrowserHistoryEntry(profileID: profile, payload: wire)
  #expect(entry.profileID == profile && entry.title == "example.com" && entry.visitCount == 3)
  #expect(entry.lastVisit == Date(timeIntervalSince1970: 2))
  for changes in [
    ["n": true], ["n": -1], ["n": 1.5], ["n": Double.infinity],
    ["v": [true]], ["v": []], ["v": [-1]], ["v": [Double.nan]], ["v": [1e100]],
    ["u": "https://example.com/\0bad"],
    ["u": "https://example.com/" + String(repeating: "x", count: 32768)],
  ] as [[String: Any]] {
    var value = wire
    value.merge(changes) { _, new in new }
    #expect(throws: LibraryDataError.self) {
      try BrowserHistoryEntry(profileID: profile, payload: value)
    }
  }
}

@Test func launcherLibraryResultsStayInSelectedProfileAndPreferBookmarksToDuplicateHistory() throws
{
  var session = BrowserSession.fresh()
  let a = session.spaces[0].profileID
  let b = session.spaces[1].profileID
  let sharedID = UUID()
  let alpha = try BookmarkTree(
    profileID: a,
    payload: bookmarkPayload(children: [
      [
        "id": sharedID.uuidString, "k": "u", "t": "Unique console",
        "u": "https://alpha.example.com",
      ]
    ]))
  let beta = try BookmarkTree(
    profileID: b,
    payload: bookmarkPayload(children: [
      ["id": sharedID.uuidString, "k": "u", "t": "Unique console", "u": "https://beta.example.com"]
    ]))
  let histories = try [(a, "alpha"), (b, "beta")].map { profile, name in
    try BrowserHistoryEntry(
      profileID: profile,
      payload: ["u": "https://\(name).example.com", "t": "Unique console", "n": 1, "v": [1000]])
  }
  let bookmarks = alpha.items + beta.items
  let first = CommandSearch.results(
    for: "Unique", in: session, bookmarks: bookmarks, history: histories)
  #expect(first.contains { $0.action == .bookmark(profile: a, id: sharedID) })
  #expect(!first.contains { $0.action == .bookmark(profile: b, id: sharedID) })
  #expect(
    !first.contains {
      if case .history = $0.action { return true }
      return false
    })
  session.cycleSpace(by: 1)
  let second = CommandSearch.results(
    for: "Unique", in: session, bookmarks: bookmarks, history: histories)
  #expect(second.contains { $0.action == .bookmark(profile: b, id: sharedID) })
  #expect(!second.contains { $0.action == .bookmark(profile: a, id: sharedID) })
}

private func bookmarkPayload(children: [[String: Any]]) -> [String: Any] {
  [
    "bar": [
      "id": "00000000-0000-4000-8000-000000000001", "k": "f", "t": "Bookmarks bar", "c": children,
    ],
    "other": [
      "id": "00000000-0000-4000-8000-000000000002", "k": "f", "t": "Other bookmarks", "c": [],
    ],
  ]
}
