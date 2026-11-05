// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct TabSwitcherControllerTests {
  @Test func closedBackgroundTabDisappearsFromActiveSwitcher() throws {
    let store = BrowserStore()
    let controller = TabSwitcherController()
    store.perform(.open(URL(string: "https://example.com/first")!))
    let first = try #require(store.session.selectedPage?.tab.id)
    controller.record(store: store)
    store.perform(.open(URL(string: "https://example.com/second")!))
    let second = try #require(store.session.selectedPage?.tab.id)
    controller.record(store: store)
    store.perform(.open(URL(string: "https://example.com/third")!))
    let third = try #require(store.session.selectedPage?.tab.id)
    controller.record(store: store)

    controller.advance(store: store, reverse: false)
    #expect(controller.choices == [third, second, first])
    #expect(controller.choices[controller.index] == second)

    store.closeTab(second)
    controller.record(store: store)
    #expect(controller.choices == [third, first])
    #expect(controller.choices[controller.index] == first)
    controller.commit(store: store)
    #expect(store.session.selectedPage?.tab.id == first)
  }
}
