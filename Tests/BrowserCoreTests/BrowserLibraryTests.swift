// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

@Test func whitespaceBookmarkTitlesUseUntitledFallbacks() throws {
  let session = BrowserSession.fresh()
  let folderID = UUID()
  let bookmarkID = UUID()
  let tree = try BookmarkTree(
    profileID: session.selectedSpace.profileID,
    payload: bookmarkPayload(children: [
      [
        "id": folderID.uuidString, "k": "f", "t": " \t ",
        "c": [
          [
            "id": bookmarkID.uuidString, "k": "u", "t": " \n ",
            "u": "https://docs.example.com/read",
          ]
        ],
      ]
    ]))
  let folder = try #require(tree.items.first { $0.id == folderID })
  let bookmark = try #require(tree.items.first { $0.id == bookmarkID })
  let sections = CommandLauncher.sections(
    for: "docs.example.com", filter: .bookmarks, in: session,
    sources: CommandSources(bookmarks: tree.items))

  #expect(folder.title == "Untitled folder")
  #expect(bookmark.title == "Untitled bookmark")
  #expect(bookmark.path.contains("Untitled folder / Untitled bookmark"))
  #expect(sections.results.first?.title == "Untitled bookmark")
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

@Test func librarySectionsAndErrorsHaveReadableTitles() {
  #expect(LibrarySection.allCases.map(\.title) == ["Bookmarks", "History"])
  #expect(LibraryDataError.invalidBookmarks.errorDescription?.contains("bookmark") == true)
  #expect(LibraryDataError.invalidHistory.errorDescription?.contains("history") == true)
}

@Test func browserImportReadsChromiumAndFirefoxBookmarksAndBuildsNestedOperations() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let chrome = directory.appendingPathComponent("Bookmarks.json")
  let chromeData = try JSONSerialization.data(withJSONObject: [
    "roots": [
      "bookmark_bar": [
        "children": [
          [
            "type": "folder", "name": "Work",
            "children": [
              ["type": "url", "name": "Portal", "url": "https://work.example.com"]
            ],
          ]
        ]
      ]
    ]
  ])
  try chromeData.write(to: chrome)
  let chromiumItems = try BrowserImport.read(chrome)
  #expect(chromiumItems.count == 1)
  #expect(chromiumItems[0].folder == "Work")

  let firefox = directory.appendingPathComponent("Bookmarks.html")
  try #"<DL><DT><H3>Personal</H3><DL><DT><A HREF="https://home.example.com">Home</A></DL></DL>"#
    .write(
      to: firefox, atomically: true, encoding: .utf8)
  let firefoxItems = try BrowserImport.read(firefox)
  #expect(firefoxItems.map(\.address) == ["https://home.example.com"])

  let rootID = UUID()
  let operations = BrowserImport.operations(
    for: chromiumItems + firefoxItems, otherFolderID: rootID)
  #expect(operations.count == 4)
  #expect(operations[0]["t"] as? String == "Work")
  #expect(operations[0]["parent"] as? String == rootID.uuidString.lowercased())
  #expect(operations[1]["parent"] as? String == operations[0]["id"] as? String)
  #expect(operations[2]["t"] as? String == "Personal")
  #expect(operations[2]["parent"] as? String == rootID.uuidString.lowercased())
  #expect(operations[3]["parent"] as? String == operations[2]["id"] as? String)
}

@Test func browserImportReadsSafariPlistsAndFirefoxJSONAndRejectsUnsupportedFiles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let safari = directory.appendingPathComponent("Bookmarks.plist")
  let plist: [String: Any] = [
    "Children": [
      [
        "Title": "Safari", "URLString": "https://safari.example.com",
      ]
    ]
  ]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
    to: safari)
  #expect(try BrowserImport.read(safari).map(\.title) == ["Safari"])

  let firefoxJSON = directory.appendingPathComponent("Firefox.json")
  try JSONSerialization.data(withJSONObject: [
    "type": "text/x-moz-place-container", "title": "Root",
    "children": [
      ["type": "text/x-moz-place", "title": "Firefox", "uri": "https://firefox.example.com"]
    ],
  ]).write(to: firefoxJSON)
  #expect(try BrowserImport.read(firefoxJSON).map(\.address) == ["https://firefox.example.com"])

  let unsupported = directory.appendingPathComponent("Unsupported.json")
  try Data("{}".utf8).write(to: unsupported)
  #expect(throws: BrowserImport.ImportError.self) { try BrowserImport.read(unsupported) }
}

@Test func browserImportCoversNestedAndMalformedExportShapes() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let chromium = directory.appendingPathComponent("Arc.json")
  try JSONSerialization.data(withJSONObject: [
    "roots": [
      "bookmark_bar": [
        "children": [
          [
            "name": "Repeated",
            "children": [
              ["title": "First", "url": "https://first.example.com"],
              ["name": "Invalid", "url": "javascript:alert(1)"],
              ["name": "Untitled child", "c": [["uri": "https://second.example.com"]]],
            ],
          ]
        ]
      ],
      "other": ["children": [["name": "Other", "url": "https://other.example.com"]]],
      "synced": ["children": [["name": "Synced", "url": "https://synced.example.com"]]],
    ]
  ]).write(to: chromium)
  let chromiumItems = try BrowserImport.read(chromium)
  #expect(chromiumItems.count == 4)
  #expect(
    chromiumItems.contains { $0.title == "Untitled" && $0.folder == "Repeated / Untitled child" })
  #expect(!chromiumItems.contains { $0.title == "Invalid" })

  let emptyChromium = directory.appendingPathComponent("EmptyChrome.json")
  try JSONSerialization.data(withJSONObject: ["roots": ["bookmark_bar": [:]]]).write(
    to: emptyChromium)
  #expect(try BrowserImport.read(emptyChromium).isEmpty)

  let safari = directory.appendingPathComponent("Nested.plist")
  try PropertyListSerialization.data(
    fromPropertyList: [
      "Children": [
        [
          "Title": "Folder",
          "Children": [
            ["Title": "Nested page", "URLString": "https://nested.example.com"],
            ["Title": "Bad URL", "URLString": "file:///private/data"],
            ["Children": [["URLString": "https://untitled.example.com"]]],
          ],
        ]
      ]
    ], format: .xml, options: 0
  ).write(to: safari)
  let safariItems = try BrowserImport.read(safari)
  #expect(safariItems.map(\.folder) == ["Folder", "Folder / Untitled"])
  #expect(safariItems[1].title == "Untitled")

  let emptySafari = directory.appendingPathComponent("EmptySafari.plist")
  try PropertyListSerialization.data(
    fromPropertyList: ["Unexpected": "root"], format: .xml, options: 0
  )
  .write(to: emptySafari)
  #expect(try BrowserImport.read(emptySafari).isEmpty)

  let firefox = directory.appendingPathComponent("Nested.json")
  try JSONSerialization.data(withJSONObject: [
    "children": [
      [
        "title": "Folder",
        "children": [
          ["name": "Page", "uri": "https://firefox.example.com"],
          ["title": "Bad", "uri": "javascript:void(0)"],
        ],
      ],
      ["name": "Empty folder", "children": []],
    ]
  ]).write(to: firefox)
  let firefoxItems = try BrowserImport.read(firefox)
  #expect(firefoxItems.count == 1 && firefoxItems[0].folder == "Untitled / Folder")

  let emptyFirefox = directory.appendingPathComponent("EmptyFirefox.json")
  try JSONSerialization.data(withJSONObject: [
    "type": "text/x-moz-place-container", "children": [],
  ]).write(to: emptyFirefox)
  #expect(try BrowserImport.read(emptyFirefox).isEmpty)

  let html = directory.appendingPathComponent("Encoded.html")
  try
    #"<DL><p><DT><H3>Work</H3><DL><p><DT><H3>Research</H3><DL><p><DT><A href='https://example.com/?a=1&amp;b=2' title='ignored'>A &amp; B</A></DL><p></DL><p><DT><A HREF="javascript:bad()">bad</A></DL>"#
    .write(to: html, atomically: true, encoding: .utf8)
  let htmlItems = try BrowserImport.read(html)
  #expect(htmlItems.count == 1)
  #expect(htmlItems[0].address == "https://example.com/?a=1&b=2")
  #expect(htmlItems[0].title == "A & B")
  #expect(htmlItems[0].folder == "Work / Research")

  let emptyHTML = directory.appendingPathComponent("Empty.html")
  try "<DL><DT>No bookmarks</DT></DL>".write(
    to: emptyHTML, atomically: true, encoding: .utf8)
  #expect(try BrowserImport.read(emptyHTML).isEmpty)

  let nonDictionaryJSON = directory.appendingPathComponent("Array.json")
  try JSONSerialization.data(withJSONObject: ["bookmarks"]).write(to: nonDictionaryJSON)
  #expect(throws: BrowserImport.ImportError.self) { try BrowserImport.read(nonDictionaryJSON) }

  let nonDictionaryPlist = directory.appendingPathComponent("Array.plist")
  try PropertyListSerialization.data(fromPropertyList: ["bookmarks"], format: .xml, options: 0)
    .write(to: nonDictionaryPlist)
  #expect(throws: BrowserImport.ImportError.self) { try BrowserImport.read(nonDictionaryPlist) }
  #expect(BrowserImport.ImportError.unsupported.errorDescription?.contains("Firefox") == true)

  let nonUTF8HTML = directory.appendingPathComponent("Binary.html")
  try Data([0xFF, 0xFE]).write(to: nonUTF8HTML)
  #expect(throws: BrowserImport.ImportError.self) { try BrowserImport.read(nonUTF8HTML) }

  let ignoredHistory = BrowserImportItem(
    kind: .history, title: "History", address: "https://history.example.com")
  let sharedFolderOperations = BrowserImport.operations(
    for: [chromiumItems[0], chromiumItems[1], ignoredHistory], otherFolderID: UUID())
  #expect(sharedFolderOperations.filter { $0["k"] as? String == "f" }.count == 2)
  #expect(sharedFolderOperations.filter { $0["k"] as? String == "u" }.count == 2)
}

@Test func browserImportIncludesChromeMobileRoot() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: "Chrome-\(UUID()).json")
  defer { try? FileManager.default.removeItem(at: url) }
  try JSONSerialization.data(withJSONObject: [
    "roots": [
      "mobile": ["children": [["name": "Phone bookmark", "url": "https://phone.example"]]]
    ]
  ]).write(to: url)

  #expect(try BrowserImport.read(url).map(\.title) == ["Phone bookmark"])
}

@Test func browserImportDecodesBookmarkHTMLCharacterReferences() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: "Firefox-\(UUID()).html")
  defer { try? FileManager.default.removeItem(at: url) }
  try
    #"<DL><DT><A HREF="https://example.com">R&amp;D &lt;map&gt; &#39;guide&#39; &#x1F30D; &apos; &unknown;</A></DL>"#
    .write(to: url, atomically: true, encoding: .utf8)

  let items = try BrowserImport.read(url)
  #expect(items.map(\.title) == ["R&D <map> 'guide' 🌍 ' &unknown;"])
}

@Test func firefoxJSONRootDoesNotBecomeAnImportedFolder() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: "Firefox-\(UUID()).json")
  defer { try? FileManager.default.removeItem(at: url) }
  try JSONSerialization.data(withJSONObject: [
    "guid": "root________", "title": "", "type": "text/x-moz-place-container",
    "children": [
      [
        "guid": "menu________", "title": "Bookmarks Menu", "type": "text/x-moz-place-container",
        "children": [["title": "Page", "uri": "https://page.example"]],
      ]
    ],
  ]).write(to: url)

  let items = try BrowserImport.read(url)
  #expect(items.map(\.folder) == ["Bookmarks Menu"])
  let operations = BrowserImport.operations(for: items, otherFolderID: UUID())
  #expect(operations.count == 2 && operations[0]["t"] as? String == "Bookmarks Menu")
}

@Test func browserImportKeepsSlashInsideFolderName() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: "Chrome-\(UUID()).json")
  defer { try? FileManager.default.removeItem(at: url) }
  try JSONSerialization.data(withJSONObject: [
    "roots": [
      "bookmark_bar": [
        "children": [
          [
            "name": "Research / Media",
            "children": [
              [
                "name": "Archive",
                "children": [["name": "Page", "url": "https://page.example"]],
              ]
            ],
          ],
          [
            "name": "Research",
            "children": [
              [
                "name": "Media / Archive",
                "children": [["name": "Second page", "url": "https://second.example"]],
              ]
            ],
          ],
        ]
      ]
    ]
  ]).write(to: url)

  let items = try BrowserImport.read(url)
  #expect(
    items.map(\.folderComponents) == [
      ["Research / Media", "Archive"], ["Research", "Media / Archive"],
    ])
  let operations = BrowserImport.operations(for: items, otherFolderID: UUID())
  #expect(operations.count == 6)
  #expect(operations[0]["t"] as? String == "Research / Media")
  #expect(operations[3]["t"] as? String == "Research")
  #expect(operations[5]["parent"] as? String != operations[2]["parent"] as? String)
}

@Test @MainActor func browserImportBatchAppliesInOrderAndStopsAfterAnError() {
  let operations: [[String: Any]] = [["id": "first"], ["id": "second"], ["id": "third"]]
  var applied: [String] = []
  var result: Error?
  BrowserImport.apply(
    operations,
    using: { operation, done in
      applied.append(operation["id"] as? String ?? "")
      done(nil)
    }, completion: { result = $0 })
  #expect(applied == ["first", "second", "third"] && result == nil)

  let failure = NSError(domain: "test", code: 1)
  applied = []
  BrowserImport.apply(
    operations,
    using: { operation, done in
      applied.append(operation["id"] as? String ?? "")
      done(applied.count == 2 ? failure : nil)
    }, completion: { result = $0 })
  #expect(applied == ["first", "second"] && (result as NSError?) == failure)

  applied = []
  BrowserImport.apply(
    [],
    using: { operation, _ in
      applied.append(operation["id"] as? String ?? "")
    }, completion: { result = $0 })
  #expect(applied.isEmpty && result == nil)
}
