import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ExternalAppRoutingTests {
  @Test func externalContextRejectsUnboundTargetsAndDuplicateCannotMoveOwnership() throws {
    let router = BrowserRuntimeRouter()
    let first = BrowserRuntimeClient(windowID: "first") { ["shared"] }
    let second = BrowserRuntimeClient(windowID: "second") { ["shared"] }
    try router.register(first)
    try router.register(second)
    #expect(router.bindTab("one", windowID: "first"))
    #expect(router.bindTab("two", windowID: "second"))
    #expect(
      router.claim(.externalApp, id: "x1", payload: ["windowID": "first", "tabID": "one"]) === first
    )
    #expect(
      router.claim(.externalApp, id: "x1", payload: ["windowID": "second", "tabID": "two"]) == nil)
    #expect(router.client(for: .externalApp, id: "x1") === first)
    #expect(!router.consume(.externalApp, id: "x1", windowID: "second"))
    #expect(router.consume(.externalApp, id: "x1", windowID: "first"))
    #expect(!router.consume(.externalApp, id: "x1", windowID: "first"))
  }

  @Test func externalContextRequiresExactBoundWindowAndTabAndClosesWithOwner() throws {
    let router = BrowserRuntimeRouter()
    let first = BrowserRuntimeClient(windowID: "first") { ["shared"] }
    let second = BrowserRuntimeClient(windowID: "second") { ["shared"] }
    try router.register(first)
    try router.register(second)
    #expect(router.bindTab("one", windowID: "first"))
    #expect(router.bindTab("two", windowID: "second"))
    #expect(
      router.claim(.externalApp, id: "x2", payload: ["windowID": "missing", "tabID": "one"]) == nil)
    #expect(
      router.claim(.externalApp, id: "x2", payload: ["windowID": "first", "tabID": "two"]) == nil)
    #expect(
      router.claim(.externalApp, id: "x2", payload: ["windowID": "first", "tabID": "one"]) === first
    )
    router.windowClosed("first", quitting: false)
    #expect(router.client(for: .externalApp, id: "x2") == nil)
    #expect(router.clients(forProfile: "shared").count == 1)
  }

  @Test func externalContextCanBeRemovedWhenClaimedClientHasNoReceiver() throws {
    let router = BrowserRuntimeRouter()
    let client = BrowserRuntimeClient(windowID: "owner") { ["shared"] }
    try router.register(client)
    #expect(router.bindTab("tab", windowID: "owner"))
    #expect(
      router.claim(.externalApp, id: "x3", payload: ["windowID": "owner", "tabID": "tab"])
        === client)
    #expect(client.onExternalAppRequest == nil)
    #expect(router.consume(.externalApp, id: "x3", windowID: "owner"))
    #expect(!router.owns(.externalApp, id: "x3"))
    #expect(!router.consume(.externalApp, id: "x3", windowID: "owner"))
  }
}
