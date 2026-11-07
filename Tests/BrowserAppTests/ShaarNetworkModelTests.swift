// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarNetworkModelTests {
  @Test func webSocketLifecycleShowsStatusAndFramesInWSFilter() {
    let model = ShaarNetworkModel()
    let id = "socket-1"
    let frame = ShaarWebSocketFrame(
      direction: .received, opcode: 1, payload: "echo-ready", time: 1.2)
    let events: [ShaarDevToolsEvent] = [
      .network(
        .init(
          id: UUID(), method: "GET", url: "ws://127.0.0.1:3212/ws",
          status: nil, requestID: id, phase: .webSocketCreated, time: 1)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: 101,
          requestID: id, phase: .webSocketHandshake, time: 1.1)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: nil,
          requestID: id, phase: .webSocketFrame, time: 1.2, frame: frame)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: nil,
          requestID: id, phase: .webSocketClosed, time: 2)),
    ]
    model.filter = .socket
    let rows = model.visibleRequests(from: events)
    #expect(rows.count == 1)
    #expect(rows[0].status == 101)
    #expect(rows[0].frames == [frame])
    #expect(rows[0].completedAt == 2)
    #expect(ShaarNetworkModel.DetailTab.allCases.contains(.messages))
  }

  @Test func fiftyThousandRequestFilterProjectsOffMainActor() async {
    let events: [ShaarDevToolsEvent] = (0..<50_000).map { index in
      .network(
        .init(
          id: UUID(), method: "GET", url: "https://example.com/item/\(index)",
          status: index.isMultiple(of: 2) ? 500 : 200, time: Double(index)))
    }
    let model = ShaarNetworkModel()
    model.scheduleRows(from: events)
    model.filter = .errors
    model.scheduleRows(from: events)
    let start = ContinuousClock.now
    for _ in 0..<500 where model.projection.result?.rows.count != 25_000 {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let elapsed = start.duration(to: .now)
    print("Network 50,000-request projection: \(elapsed)")
    #expect(model.projection.result?.rows.count == 25_000)
    #expect(model.projection.result?.totalCount == 50_000)
    #expect(elapsed < .seconds(5))
  }

  @Test func phasesMergeByRequestIDAndFiltersUseFinalState() {
    let model = ShaarNetworkModel()
    let id = UUID()
    let events: [ShaarDevToolsEvent] = [
      .network(
        .init(
          id: id, method: "GET", url: "https://example.com/api/orders", status: nil,
          requestID: "request-1", phase: .request, time: 1)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: 503,
          requestID: "request-1", phase: .response, mimeType: "application/json", time: 1.1)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: nil,
          requestID: "request-1", phase: .data, encodedBytes: 40, time: 1.2)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: nil,
          requestID: "request-1", phase: .finished, encodedBytes: 64, time: 1.25)),
      .network(
        .init(
          id: UUID(), method: "GET", url: "https://example.com/app.css", status: 200,
          mimeType: "text/css", encodedBytes: 1024, time: 2)),
    ]
    let rows = model.requests(from: events)
    #expect(rows.count == 2)
    #expect(rows[0].status == 503 && rows[0].encodedBytes == 64)
    #expect(rows[0].duration == 0.25 && rows[0].resource == .fetch)
    #expect(rows[0].respondedAt == 1.1)
    model.filter = .errors
    #expect(model.visibleRequests(from: events).map(\.id) == ["request-1"])
    model.filter = .style
    #expect(model.visibleRequests(from: events).count == 1)
    model.search = "missing"
    #expect(model.visibleRequests(from: events).isEmpty)
  }

  @Test func responseOnlyDocumentUsesUnambiguousSameURLMethod() {
    let model = ShaarNetworkModel()
    let url = "https://example.com/en-US"
    let events: [ShaarDevToolsEvent] = [
      .network(.init(id: UUID(), method: "GET", url: url, status: 200,
                     requestID: "document-request", phase: .response,
                     mimeType: "text/html")),
      .network(.init(id: UUID(), method: "", url: url, status: 200,
                     requestID: "document-response", phase: .response,
                     mimeType: "text/html")),
      .network(.init(id: UUID(), method: "", url: "https://example.com/api",
                     status: 200, requestID: "api-response", phase: .response,
                     mimeType: "application/json")),
    ]
    let rows = model.requests(from: events)
    #expect(rows.map(\.method) == ["GET", "GET", ""])

    let ambiguous = events + [
      .network(.init(id: UUID(), method: "POST", url: url, status: 200,
                     requestID: "posted-document", phase: .response,
                     mimeType: "text/html"))
    ]
    #expect(model.requests(from: ambiguous)[1].method.isEmpty)
  }

  @Test func copiesEscapeCommandsAndRedactSensitiveHeaders() {
    let model = ShaarNetworkModel()
    let event = ShaarNetworkEvent(
      id: UUID(), method: "POST", url: "https://example.com/api?q=a'b", status: 201,
      requestHeaders: [
        .init(name: "Authorization", value: "Bearer secret"),
        .init(name: "Content-Type", value: "application/json"),
      ], responseHeaders: [.init(name: "Set-Cookie", value: "session=secret")],
      payload: "{\"name\":\"A\"}")
    let row = model.requests(from: [.network(event)])[0]
    let curl = model.curlCommand(for: row)
    let fetch = model.fetchCommand(for: row)
    let agent = model.agentCopyText(for: row)
    #expect(curl.contains("a'\\''b"))
    #expect(fetch.hasPrefix("fetch(") && fetch.contains("a'b"))
    #expect(!curl.contains("Bearer secret") && !fetch.contains("Bearer secret"))
    #expect(!agent.contains("session=secret"))
    #expect(curl.contains("[redacted]") && agent.contains("[redacted]"))
  }

  @Test func responseTreeIsBoundedAndSelectionResets() {
    let model = ShaarNetworkModel()
    let tree = model.jsonTree(
      for: "{\"items\":[{\"id\":4}]}"
    )
    #expect(tree?.first?.children.first?.name == "items")
    #expect(tree?.first?.children.first?.children.first?.children.first?.value == "4")
    #expect(model.jsonTree(for: String(repeating: "x", count: 1_048_577)) == nil)
    let many = "[" + Array(repeating: "{\"a\":1,\"b\":2}", count: 400).joined(separator: ",") + "]"
    let bounded = model.jsonTree(for: many)
    #expect((bounded?.first?.children.count ?? 0) < 100)
    #expect(bounded?.first?.children.last?.name == "…")
    let orphan = ShaarNetworkEvent(
      id: UUID(), method: "", url: "", status: nil,
      requestID: "orphan", phase: .finished, time: 1)
    #expect(model.requests(from: [.network(orphan)]).isEmpty)
    model.selectedID = "one"
    model.detailTab = .response
    model.clearSelection()
    #expect(model.selectedID == nil && model.detailTab == .headers)
    let rows = model.requests(from: [
      .network(.init(id: UUID(), method: "GET", url: "https://example.com/a", status: 200)),
      .network(.init(id: UUID(), method: "GET", url: "https://example.com/b", status: 200)),
    ])
    model.selectAdjacent(in: rows, forward: true)
    #expect(model.selectedID == rows[0].id)
    model.selectAdjacent(in: rows, forward: true)
    #expect(model.selectedID == rows[1].id)
    model.selectAdjacent(in: rows, forward: false)
    #expect(model.selectedID == rows[0].id)
  }

  @Test func statusFilterIsSeparateFromResourceType() {
    let model = ShaarNetworkModel()
    let events: [ShaarDevToolsEvent] = [
      .network(.init(id: UUID(), method: "GET", url: "https://example.com/ok", status: 204)),
      .network(.init(id: UUID(), method: "GET", url: "https://example.com/moved", status: 302)),
      .network(.init(id: UUID(), method: "GET", url: "https://example.com/missing", status: 404)),
      .network(
        .init(
          id: UUID(), method: "GET", url: "https://example.com/down", status: nil,
          phase: .failed, failure: "Failed")),
    ]
    model.statusFilter = .success
    #expect(model.visibleRequests(from: events).map(\.url) == ["https://example.com/ok"])
    model.statusFilter = .redirect
    #expect(model.visibleRequests(from: events).map(\.status) == [302])
    model.statusFilter = .clientError
    #expect(model.visibleRequests(from: events).map(\.status) == [404])
    model.statusFilter = .failed
    #expect(model.visibleRequests(from: events).map(\.failure) == ["Failed"])
    model.statusFilter = .any
    model.filter = .errors
    #expect(model.visibleRequests(from: events).count == 2)
  }

  @Test func storedBodyFeedsPreviewAndHARRedactsHeaders() async {
    let model = ShaarNetworkModel()
    let event = ShaarNetworkEvent(
      id: UUID(), method: "POST", url: "https://example.com/api", status: 200,
      requestID: "body-1", mimeType: "application/json",
      requestHeaders: [.init(name: "Authorization", value: "Bearer secret")],
      payload: "{\"q\":1}")
    model.loadBody = { _ in
      ShaarStoredResponseBody(body: "{\"ok\":true}", base64Encoded: false)
    }
    await model.loadResponseBody(id: "body-1")
    let row = model.exportRequests(from: [.network(event)])[0]
    #expect(row.responseBody == "{\"ok\":true}")
    #expect(model.jsonTree(for: row.responseBody ?? "")?.first?.children.first?.name == "ok")
    let image = ShaarStoredResponseBody(
      body: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(), base64Encoded: true)
    let presented = ShaarNetworkBodyPresentation.apply(image, mime: "image/png")
    #expect(presented.binary && presented.image?.count == 4 && presented.text.isEmpty)
    let har = String(decoding: ShaarNetworkHAR.document(requests: [row]), as: UTF8.self)
    #expect(har.contains("example.com\\/api"))
    #expect(har.contains("{\\\"ok\\\":true}") || har.contains("{\"ok\":true}"))
    #expect(har.contains("[redacted]"))
    #expect(!har.contains("Bearer secret"))
    #expect(ShaarNetworkThrottle.slow3G.parameters["latency"] as? Int == 400)
    #expect(ShaarNetworkThrottle.fast3G.parameters["downloadThroughput"] as? Int == 200_000)
    #expect(ShaarNetworkThrottle.none.parameters["offline"] as? Bool == false)
    #expect(ShaarNetworkThrottle.offline.parameters["offline"] as? Bool == true)
  }

  @Test func networkConditionsAndPreviewRenderOffscreen() async throws {
    _ = NSApplication.shared
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let requestID = "orders-1"
    let fixture: [ShaarDevToolsEvent] = [
      .network(
        .init(
          id: UUID(), method: "POST", url: "http://localhost:3000/api/orders",
          status: nil, requestID: requestID, phase: .request, time: 0.3)),
      .network(
        .init(
          id: UUID(), method: "", url: "", status: 503, requestID: requestID,
          phase: .response, mimeType: "application/json", time: 0.48,
          responseBody: "{\"error\":\"Service unavailable\"}")),
    ]
    let shell = ShaarDevToolsModel(
      target: target,
      transport: ShaarDevToolsFixtureTransport(fixture: fixture),
      layoutDefaults: UserDefaults(suiteName: "ShaarNetworkTools.\(UUID().uuidString)")!)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .network
    for _ in 0..<40 where shell.events.count < fixture.count { await Task.yield() }
    #expect(shell.events.count == fixture.count)
    shell.network.selectedID = requestID
    shell.network.statusFilter = .serverError
    shell.network.conditions.throttle = .slow3G
    shell.network.conditions.cacheDisabled = true
    shell.network.conditions.applyThrottle = { _ in
      throw DeveloperModeFailure("Throttle was rejected.")
    }
    await shell.network.conditions.select(.offline)
    #expect(shell.network.conditions.failure == "Throttle was rejected.")
    shell.network.detailTab = .preview
    let preview = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    shell.network.detailTab = .response
    let response = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!preview.isEmpty)
    #expect(!response.isEmpty)
    shell.close()
  }
}
