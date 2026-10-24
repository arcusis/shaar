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
    first.onTabClosed = { closed.append("first:\($0)") }
    second.onTabClosed = { closed.append("second:\($0)") }
    #expect(router.bindTab("tab", windowID: "first"))
    #expect(!router.bindTab("tab", windowID: "second"))
    #expect(!router.bindTab("unknown", windowID: "missing"))
    router.forgetTab("tab", windowID: "second")
    #expect(router.client(forTab: "tab", nativeWindowID: "first") === first)
    #expect(router.client(forTab: "tab", nativeWindowID: "second") == nil)
    #expect(router.client(forTab: "tab", nativeWindowID: nil) == nil)
    router.tabClosed("tab")
    router.tabClosed("tab")
    router.tabClosed("foreign")
    #expect(closed == ["first:tab"])
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
    weak var weakFirst = first
    first = nil
    #expect(weakFirst == nil)
    #expect(router.clients(forProfile: "shared").map(\.windowID) == ["second"])
  }
}
