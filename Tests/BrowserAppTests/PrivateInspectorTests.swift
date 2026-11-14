// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

private final class PrivateInspectorRuntime: ARCChromiumRuntime {
  var tabID = ""
  var pageView: NSView?
  var calls: [String] = []
  var expressions: [String] = []
  var ended: [String] = []
  var opened = false
  var toggleError: Error?
  var pendingAuditReplies: [@MainActor @Sendable ([String: Any]?, Error?) -> Void] = []

  override func view(forPrivateTabID tabID: String, windowID: String, contextID: String) -> NSView?
  {
    guard tabID == self.tabID, windowID == "private-window", contextID == "private-context"
    else { return nil }
    return pageView
  }

  override func beginInspector(forPrivateTabID tabID: String, windowID: String, contextID: String)
    -> Bool
  {
    view(forPrivateTabID: tabID, windowID: windowID, contextID: contextID) != nil
  }

  override func endInspector(forTabID tabID: String) { ended.append(tabID) }

  @MainActor override func privateInspectorCall(
    _ method: String, params: [AnyHashable: Any], tabID: String, windowID: String,
    contextID: String,
    completion: @escaping @MainActor @Sendable ([String: Any]?, Error?) -> Void
  ) {
    guard view(forPrivateTabID: tabID, windowID: windowID, contextID: contextID) != nil else {
      completion(nil, InspectorFailure("Wrong scope"))
      return
    }
    calls.append(method)
    if let expression = params["expression"] as? String { expressions.append(expression) }
    if (params["expression"] as? String)?.contains("axe.version !== '4.14.0'") == true {
      pendingAuditReplies.append(completion)
      return
    }
    completion(["result": ["value": 42]], nil)
  }

  @MainActor override func toggleDevTools(
    forPrivateTabID tabID: String, windowID: String, contextID: String,
    completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    opened = view(forPrivateTabID: tabID, windowID: windowID, contextID: contextID) != nil
    completion(toggleError)
  }
}

@Suite @MainActor struct PrivateInspectorTests {
  @Test func cancelledAuditCannotClearTheReplacementOperation() async throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: tabID))
    let runtime = PrivateInspectorRuntime()
    runtime.tabID = tabID.uuidString
    runtime.pageView = NSView()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context", windowID: "private-window",
      firstTabID: tabID, store: store)
    session.toggleInspector()
    let audit = try #require(session.inspectors[tabID]?.details.audit)

    audit.run()
    for _ in 0..<100 where runtime.pendingAuditReplies.count < 1 { await Task.yield() }
    #expect(runtime.pendingAuditReplies.count == 1)
    audit.cancel()
    audit.run()
    for _ in 0..<100 where runtime.pendingAuditReplies.count < 2 { await Task.yield() }
    #expect(runtime.pendingAuditReplies.count == 2)

    let reply: [String: Any] = ["result": ["value": [
      "scope": "page", "violations": 0, "incomplete": 0, "findings": [], "truncated": false,
    ]]]
    runtime.pendingAuditReplies[0](reply, nil)
    try await Task.sleep(for: .milliseconds(10))
    #expect(audit.busy)

    runtime.pendingAuditReplies[1](reply, nil)
    try await Task.sleep(for: .milliseconds(10))
    #expect(!audit.busy)
    #expect(audit.report?.scope == "page")
    session.retireInspectors()
  }

  @Test func privateDeveloperToolsFailureUsesLocalizedNotice() throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: tabID))
    let runtime = PrivateInspectorRuntime()
    runtime.tabID = tabID.uuidString
    runtime.pageView = NSView()
    runtime.toggleError = NSError(
      domain: "DevTools", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context", windowID: "private-window",
      firstTabID: tabID, store: store)

    session.toggleChromiumDeveloperTools()

    #expect(
      session.failure
        == ShellL10n.string(
          "Could not open developer tools in this private window. Try again."))
  }

  @Test func closingReleasedInspectorStillRemovesRendererShield() async throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(sourceProfileID: UUID(), firstTabID: tabID))
    let runtime = PrivateInspectorRuntime()
    runtime.tabID = tabID.uuidString
    runtime.pageView = NSView()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context", windowID: "private-window",
      firstTabID: tabID, store: store)
    let target = try #require(session.inspectorTarget)
    var model: InspectorModel? = InspectorModel(target: target, privateSession: session)
    weak let released = model
    model?.open()
    model?.close()
    model = nil
    for _ in 0..<20 {
      if released == nil && runtime.expressions.contains(where: { $0.contains(".stop()") }) {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(runtime.expressions.contains(where: { $0.contains(".stop()") }))
    #expect(released == nil)
  }

  @Test func privateCommandsUseTheirOwnContextAndRetireWithTheTab() async throws {
    let tabID = UUID()
    let profileID = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(
        sourceProfileID: profileID, firstTabID: tabID))
    let runtime = PrivateInspectorRuntime()
    runtime.tabID = tabID.uuidString
    runtime.pageView = NSView()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context",
      windowID: "private-window", firstTabID: tabID, store: store)
    session.tabChanged(
      tabID, url: "https://example.com/private", title: "Private",
      loading: false, back: false, forward: false)
    #expect(PrivateBrowserHost.windowCanPerform(.inspector, store: store))
    session.toggleInspector()
    let model = try #require(session.inspectors[tabID])
    #expect(model.isOpen && !model.supportsPageTools)
    #expect(try await model.evaluate("6 * 7") as? Int == 42)
    #expect(runtime.calls.contains("Runtime.evaluate"))
    model.setPanelMode(.page)
    #expect(model.panelMode == .element)
    session.toggleChromiumDeveloperTools()
    #expect(runtime.opened)
    let wrong = SiteControlTarget(tabID: tabID, profileID: UUID(), url: model.target.url)
    #expect(!session.ownsInspectorTarget(wrong))
    session.tabClosed(tabID)
    #expect(!model.isOpen && session.inspectors.isEmpty)
    #expect(runtime.ended.contains(tabID.uuidString))
    await #expect(throws: (any Error).self) { _ = try await model.evaluate("42") }
    #expect(!PrivateBrowserHost.windowCanPerform(.inspector, store: store))
  }

  @Test func retiringAWindowPreventsFurtherPrivateInspectorCalls() async throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try .privateWindow(
        sourceProfileID: UUID(), firstTabID: tabID))
    let runtime = PrivateInspectorRuntime()
    runtime.tabID = tabID.uuidString
    runtime.pageView = NSView()
    let session = PrivatePageSession(
      runtime: runtime, contextID: "private-context",
      windowID: "private-window", firstTabID: tabID, store: store)
    session.toggleInspector()
    let model = try #require(session.inspectors[tabID])
    session.retireInspectors()
    #expect(session.inspectorTarget == nil && !model.isOpen)
    await #expect(throws: (any Error).self) { _ = try await model.evaluate("42") }
    #expect(runtime.calls.isEmpty)
  }
}
