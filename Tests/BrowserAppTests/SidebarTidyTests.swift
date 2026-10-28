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
