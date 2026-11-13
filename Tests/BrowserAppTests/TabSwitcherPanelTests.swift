// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct TabSwitcherPanelTests {
  @Test func changingSpacesCancelsThePendingTabChoice() throws {
    let store = BrowserStore()
    let originalSpaceID = store.session.selectedSpaceID
    let profileID = store.session.selectedSpace.profileID
    store.perform(.open(URL(string: "https://first.example")!))
    store.perform(.open(URL(string: "https://second.example")!))
    #expect(store.createSpace(name: "Other", sharingProfile: profileID, tint: .ocean))
    let otherSpaceID = store.session.selectedSpaceID
    store.perform(.space(originalSpaceID))

    let controller = TabSwitcherController()
    controller.advance(store: store, reverse: false)
    #expect(controller.choices.count == 2)

    store.perform(.space(otherSpaceID))
    controller.record(store: store)
    #expect(controller.choices.isEmpty)

    controller.commit(store: store)
    #expect(store.session.selectedSpaceID == otherSpaceID)
  }
}
