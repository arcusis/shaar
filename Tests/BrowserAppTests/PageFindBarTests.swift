// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PageFindBarTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/page")!))
    return store
  }

  @Test func barUpdatesItsCurrentQueryAndMovesInRequestedDirection() throws {
    let store = store()
    var requests: [(PageFindState, Bool)] = []
    store.onFindRequest = { state, forward in
      requests.append((state, forward))
      return true
    }
    store.showPageFind()
    let state = try #require(store.pageFind)
    let bar = PageFindBar(store: store, state: state)

    bar.updateQuery("needle")
    let current = try #require(store.pageFind)
    store.receiveFindResult(
      tabID: current.tabID, requestID: current.requestID, count: 2, active: 1, final: true)
    bar.move(forward: false)

    #expect(store.pageFind?.query == "needle")
    #expect(requests.count == 2)
    #expect(requests[0].1)
    #expect(!requests[1].1)
  }

  @Test func staleBarActionsCannotChangeAnotherFindSession() throws {
    let store = store()
    var requests = 0
    store.onFindRequest = { _, _ in
      requests += 1
      return true
    }
    store.showPageFind()
    let stale = try #require(store.pageFind)
    let bar = PageFindBar(store: store, state: stale)
    store.cycleSpace(by: 1)
    store.perform(.open(URL(string: "https://example.org/replacement")!))
    store.showPageFind()
    store.updatePageFindQuery("current query")
    let current = try #require(store.pageFind)
    store.receiveFindResult(
      tabID: current.tabID, requestID: current.requestID, count: 2, active: 1, final: true)

    bar.updateQuery("stale query")
    bar.move(forward: true)
    bar.close()

    #expect(store.pageFind?.id == current.id)
    #expect(store.pageFind?.query == "current query")
    #expect(requests == 1)
  }
}
