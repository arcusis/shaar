// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreSplitViewTests {
  @Test func commandOpenedPaneJoinsPendingSplitAndPersistsIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    store.perform(.open(URL(string: "https://first.example")!))
    let firstID = try #require(store.session.selectedSpace.selectedTabID)

    store.openSplitPane(beside: firstID, edge: .right)
    #expect(store.pendingSplitPlacement != nil)
    store.perform(.open(URL(string: "https://second.example")!))

    let secondID = try #require(store.session.selectedSpace.selectedTabID)
    let split = try #require(store.selectedSplit)
    #expect(Set(split.tabIDs) == Set([firstID, secondID]))
    #expect(store.pendingSplitPlacement == nil)
    try store.flushSaves()
    #expect(try file.load() == store.session)
  }
}
