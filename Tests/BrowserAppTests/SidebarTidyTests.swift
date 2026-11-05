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
