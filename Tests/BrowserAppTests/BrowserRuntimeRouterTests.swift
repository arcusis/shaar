// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserRuntimeRouterTests {
  @Test func duplicateOrRetiredClientsCannotReplaceExistingOwners() throws {
    let router = BrowserRuntimeRouter()
    let first = BrowserRuntimeClient(windowID: "first") { [] }
    try router.register(first)
    #expect(throws: BrowserRoutingError.self) { try router.register(first) }
    #expect(throws: BrowserRoutingError.self) {
      try router.register(BrowserRuntimeClient(windowID: "first") { [] })
    }
    router.windowClosed("first", quitting: false)
    #expect(throws: BrowserRoutingError.self) { try router.register(first) }
    #expect(!router.bindTab("late", windowID: "first"))
  }

  @Test func tabClosureRetainsItsOwnerAfterNativeMappingDisappears() throws {
    let router = BrowserRuntimeRouter()
    let first = BrowserRuntimeClient(windowID: "first") { [] }
    let second = BrowserRuntimeClient(windowID: "second") { [] }
    try router.register(first)
    try router.register(second)
    var closed: [String] = []
    first.onTabClosed = { id, _ in closed.append("first:\(id)") }
    second.onTabClosed = { id, _ in closed.append("second:\(id)") }
    #expect(router.bindTab("tab", windowID: "first"))
    #expect(!router.bindTab("tab", windowID: "second"))
    #expect(!router.bindTab("unknown", windowID: "missing"))
    router.forgetTab("tab", windowID: "second")
    #expect(router.client(forTab: "tab", nativeWindowID: "first") === first)
    #expect(router.client(forTab: "tab", nativeWindowID: "second") == nil)
    #expect(router.client(forTab: "tab", nativeWindowID: nil) == nil)
    router.tabClosed("tab", windowID: "first")
    router.tabClosed("tab", windowID: "first")
    router.tabClosed("foreign", windowID: "first")
    #expect(closed == ["first:tab"])
  }

  @Test func quitDoesNotTurnNativeTeardownIntoUserTabCloses() throws {
    let router = BrowserRuntimeRouter()
    let client = BrowserRuntimeClient(windowID: "first") { [] }
    try router.register(client)
    var closed: [String] = []
    client.onTabClosed = { id, _ in closed.append(id) }
    #expect(router.bindTab("user-closed", windowID: "first"))
    router.tabClosed("user-closed", windowID: "first")
    #expect(router.bindTab("still-open", windowID: "first"))
    router.prepareForQuit()
    router.tabClosed("still-open", windowID: "first")
    #expect(closed == ["user-closed"])
    #expect(router.client(forTab: "still-open", nativeWindowID: "first") == nil)
  }

  @Test func closedWindowTabOwnerRemainsUntilMatchingCloseEvent() throws {
    let router = BrowserRuntimeRouter()
    let source = BrowserRuntimeClient(windowID: "source") { [] }
    let destination = BrowserRuntimeClient(windowID: "destination") { [] }
    try router.register(source)
    try router.register(destination)
    #expect(router.bindTab("tab", windowID: "source"))

    router.windowClosed("source", quitting: false)

    #expect(router.tabOwnerWindowID(for: "tab") == "source")
    #expect(!router.bindTab("tab", windowID: "destination"))
    router.tabClosed("tab", windowID: "source")
    #expect(router.tabOwnerWindowID(for: "tab") == nil)
    #expect(router.bindTab("tab", windowID: "destination"))

    router.tabClosed("tab", windowID: "source")
    #expect(router.tabOwnerWindowID(for: "tab") == "destination")
    #expect(router.client(forTab: "tab", nativeWindowID: "destination") === destination)
  }

  @Test func contextIDsCannotBeClaimedOrResolvedByAnotherWindow() throws {
    let router = BrowserRuntimeRouter()
    let first = BrowserRuntimeClient(windowID: "first") { [] }
    let second = BrowserRuntimeClient(windowID: "second") { [] }
    try router.register(first)
    try router.register(second)
    #expect(router.bindTab("one", windowID: "first"))
    #expect(router.bindTab("two", windowID: "second"))
    for context in BrowserRuntimeRouter.Context.allCases {
      #expect(
        router.claim(context, id: "id", payload: ["windowID": "second", "tabID": "one"]) == nil)
      #expect(
        router.claim(context, id: "id", payload: ["windowID": "first", "tabID": "one"]) === first)
      #expect(
        router.claim(context, id: "id", payload: ["windowID": "second", "tabID": "two"]) == nil)
      #expect(!router.consume(context, id: "id", windowID: "second"))
      #expect(router.client(for: context, id: "id") === first)
      #expect(router.consume(context, id: "id", windowID: "first"))
      #expect(!router.consume(context, id: "id", windowID: "first"))
      #expect(router.client(for: context, id: "id") == nil)
    }
  }

  @Test func closingOneWindowRetiresOnlyItsContextsAndPublishesOnce() throws {
    let router = BrowserRuntimeRouter()
    let first = BrowserRuntimeClient(windowID: "first") { [] }
    let second = BrowserRuntimeClient(windowID: "second") { [] }
    try router.register(first)
    try router.register(second)
    router.bindTab("one", windowID: "first")
    router.bindTab("two", windowID: "second")
    var closure: [Bool] = []
    second.onWindowClosed = { closure.append($0) }
    for context in BrowserRuntimeRouter.Context.allCases {
      _ = router.claim(context, id: "one", payload: ["windowID": "first", "tabID": "one"])
      _ = router.claim(context, id: "two", payload: ["windowID": "second", "tabID": "two"])
    }
    router.windowClosed("second", quitting: false)
    router.windowClosed("second", quitting: true)
    #expect(closure == [false])
    #expect(router.client(forTab: "one", nativeWindowID: "first") === first)
    #expect(router.client(forTab: "two", nativeWindowID: "second") == nil)
    for context in BrowserRuntimeRouter.Context.allCases {
      #expect(router.client(for: context, id: "one") === first)
      #expect(router.client(for: context, id: "two") == nil)
    }
  }

  @Test func profileSubscribersFollowCurrentMembershipWithoutRetainingDeadWindows() throws {
    let router = BrowserRuntimeRouter()
    var memberships: Set<String> = ["shared", "beta"]
    var first: BrowserRuntimeClient? = BrowserRuntimeClient(windowID: "first") { ["shared"] }
    let second = BrowserRuntimeClient(windowID: "second") { memberships }
    try router.register(first!)
    try router.register(second)
    #expect(router.clients(forProfile: "shared").count == 2)
    #expect(router.clients(forProfile: "beta").map(\.windowID) == ["second"])
    #expect(router.clients(forProfile: "foreign").isEmpty)
    memberships.remove("beta")
    #expect(router.clients(forProfile: "beta").isEmpty)
    weak let weakFirst = first
    first = nil
    #expect(weakFirst == nil)
    #expect(router.clients(forProfile: "shared").map(\.windowID) == ["second"])
  }
}
