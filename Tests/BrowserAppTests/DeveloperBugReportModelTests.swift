// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeveloperBugReportModelTests {
  @Test func closingModelDuringArchiveDiscardsTheLateReport() async throws {
    var session = BrowserSession.fresh()
    let openedTabID = session.open(URL(string: "https://example.test/report")!)
    let tabID = try #require(openedTabID)
    let store = BrowserStore(session: session)
    let runtime = BugReportModelRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "report-window", store: store)
    defer { engine.suspensionTask?.cancel() }
    runtime.tabWindows[tabID.uuidString] = engine.windowID
    let target = SiteControlTarget(
      tabID: tabID, profileID: try #require(store.session.profileID(forTabID: tabID)),
      url: try #require(store.session.page(forTabID: tabID)?.tab.url))
    let model = DeveloperPageModel(target: target, engine: engine)
    let archive = PendingBugReportArchive()
    let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    model.bugReportArchiveWriter = { _, _ in try await archive.save(output) }

    let report = Task { await model.createBugReport() }
    await archive.waitUntilStarted()
    model.close()
    await archive.complete()

    #expect(await report.value == nil)
    #expect(model.reportURL == nil)
    #expect(model.reportFailure == nil)
    #expect(store.sheet == nil)
  }

  @Test func closedModelDoesNotStartBugReport() async throws {
    let model = DeveloperPageModel(
      target: SiteControlTarget(
        tabID: UUID(), profileID: UUID(),
        url: try #require(URL(string: "https://example.test"))),
      engine: nil)
    model.close()

    #expect(await model.createBugReport() == nil)
    #expect(!model.creatingBugReport)
    #expect(model.reportFailure == nil)
  }

  @Test func cancelledReportDoesNotPublishFailure() async {
    let model = DeveloperPageModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)

    let report = Task { @MainActor in await model.createBugReport() }
    report.cancel()
    let result = await report.value

    #expect(result == nil)
    #expect(model.reportFailure == nil)
    #expect(!model.creatingBugReport)
  }

  @Test func reportPageURLRemovesCredentialsQueryAndFragment() {
    let raw =
      "https://report-user:fixture-password@report.localhost/page?token=fixture-token#fixture-fragment"

    let value = DeveloperPageModel.redactedReportPageURL(raw)

    #expect(value == "https://report.localhost/page")
    #expect(!value.contains("fixture-password"))
    #expect(!value.contains("fixture-token"))
    #expect(!value.contains("fixture-fragment"))
  }

  @Test func consoleMessagesRedactCommonCredentialForms() {
    let raw = """
      request failed Authorization: Bearer fixture-bearer {"access_token":"fixture-json-token"} https://report-user:fixture-url-password@report.localhost/callback?custom=fixture-url-query#fixture-fragment&code=fixture-code&STATE=fixture-state eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signatureValue123
      Cookie: session=fixture-cookie
      Password: fixture password with spaces
      """

    let value = DeveloperPageModel.redactedConsoleMessage(raw)

    #expect(value.contains("request failed"))
    for secret in [
      "fixture-bearer", "fixture-json-token", "fixture-query", "fixture-code", "fixture-state",
      "fixture-cookie", "fixture password with spaces", "fixture-url-password",
      "fixture-url-query", "fixture-fragment",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.signatureValue123",
    ] {
      #expect(!value.contains(secret), "\(secret)")
    }
    #expect(value.contains("https://report.localhost/callback"))
  }
}

private actor PendingBugReportArchive {
  private var continuation: CheckedContinuation<URL, any Error>?
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var output: URL?

  func save(_ output: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      self.output = output
      started = true
      startedContinuation?.resume()
      startedContinuation = nil
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startedContinuation = $0 }
  }

  func complete() {
    guard let continuation, let output else { return }
    self.continuation = nil
    self.output = nil
    continuation.resume(returning: output)
  }
}

@MainActor
private final class BugReportModelRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var tabWindows: [String: String] = [:]

  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }
  override func downloadsDirectory(forProfileID profileID: String) -> URL? {
    FileManager.default.temporaryDirectory
  }
  override func beginDeveloperSession(
    forTabID tabID: String, profileID: String, windowID: String
  ) -> Bool { true }
  override func endDeveloperSession(forTabID tabID: String, profileID: String, windowID: String) {}

  override func developerCall(
    _ method: String, params: [AnyHashable: Any], tabID: String, profileID: String,
    windowID: String,
    completion: @escaping @MainActor @Sendable ([String: Any]?, (any Error)?) -> Void
  ) {
    if method == "Runtime.evaluate" {
      completion(["result": ["value": [
        "url": "https://example.test/report", "title": "Example", "console": [],
        "viewport": [:],
      ]]], nil)
    } else if method == "Page.captureScreenshot" {
      let pngHeader = Data([137, 80, 78, 71, 13, 10, 26, 10]).base64EncodedString()
      completion(["data": pngHeader], nil)
    } else {
      completion(["result": [:]], nil)
    }
  }
}
