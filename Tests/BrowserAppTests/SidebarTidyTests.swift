// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func tidyFallbackGroupsBySiteAndPreservesTabOrder() async {
  let first = BrowserTab(url: URL(string: "https://b.example/one")!)
  let second = BrowserTab(url: URL(string: "https://a.example")!)
  let third = BrowserTab(url: URL(string: "https://b.example/two")!)
  let grouping: any SidebarTidyGrouping = SidebarSiteGrouping()
  let groups = await grouping.groups(for: [first, second, third])
  #expect(
    groups == [
      SidebarTidyGroup(topic: "a.example", tabIDs: [second.id]),
      SidebarTidyGroup(topic: "b.example", tabIDs: [first.id, third.id]),
    ])
}

@Test func tidyFallbackKeepsDifferentLocalPortsInSeparateGroups() async {
  let first = BrowserTab(url: URL(string: "http://localhost:3000/one")!)
  let second = BrowserTab(url: URL(string: "http://localhost:4000/two")!)
  let third = BrowserTab(url: URL(string: "http://localhost:3000/three")!)
  let ipv6 = BrowserTab(url: URL(string: "http://[::1]:8080/four")!)
  let groups = await SidebarSiteGrouping().groups(for: [first, second, third, ipv6])
  #expect(groups.count == 3)
  #expect(groups.first { $0.topic == "localhost:3000" }?.tabIDs == [first.id, third.id])
  #expect(groups.first { $0.topic == "localhost:4000" }?.tabIDs == [second.id])
  #expect(groups.first { $0.topic == "[::1]:8080" }?.tabIDs == [ipv6.id])
}

@Test @MainActor func emptyTidyResultKeepsManualTodayFolderMembership() throws {
  let store = BrowserStore()
  let space = store.session.selectedSpaceID
  store.perform(.open(URL(string: "https://example.com/one")!))
  let tab = try #require(store.session.selectedSpace.selectedTab)
  let folder = try #require(store.createFolder(name: "Manual", in: space, section: .today))
  #expect(store.moveTab(tab.id, from: space, to: space, folderID: folder))

  store.applyTidyGroups([], in: space)

  #expect(store.session.selectedSpace.tabs.first { $0.id == tab.id }?.folderID == folder)
}

@Test @MainActor func repeatingTidyDoesNotCreateDuplicateEmptyFolders() throws {
  let store = BrowserStore()
  let space = store.session.selectedSpaceID
  store.perform(.open(URL(string: "https://example.com/one")!))
  let first = try #require(store.session.selectedSpace.selectedTab?.id)
  store.perform(.open(URL(string: "https://example.com/two")!))
  let second = try #require(store.session.selectedSpace.selectedTab?.id)
  let group = SidebarTidyGroup(topic: "example.com", tabIDs: [first, second])

  store.applyTidyGroups([group], in: space)
  let firstFolder = try #require(store.session.selectedSpace.folders.first?.id)
  store.applyTidyGroups([group], in: space)

  #expect(store.session.selectedSpace.folders.map(\.id) == [firstFolder])
  #expect(store.session.selectedSpace.tabs.allSatisfy { $0.folderID == firstFolder })
}
