// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarReproBundleTests {
  private let target = SiteControlTarget(
    tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/page")!)

  private func fixture() -> ShaarReproCapture {
    ShaarReproCapture(
      videoMP4: Data([0, 0, 0, 12] + Array("ftypisom".utf8)), durationSeconds: 24,
      dom: ShaarReproDOMNode(
        tag: "body", text: "", attributes: [:],
        children: [
          ShaarReproDOMNode(
            tag: "form", text: "form-secret",
            attributes: ["data-submitted-value": "attribute-secret"],
            children: [
              ShaarReproDOMNode(
                tag: "input", text: "form-secret", attributes: ["value": "form-secret"],
                children: [])
            ]),
          ShaarReproDOMNode(
            tag: "p", text: "Safe text", attributes: [:], children: []),
        ]),
      console: [
        ShaarConsoleEvent(
          id: UUID(), level: .warning, message: "Fixture warning", source: "page.js")
      ],
      network: [
        ShaarNetworkEvent(
          id: UUID(), method: "POST", url: "https://example.com/api", status: 200,
          requestHeaders: [
            ShaarNetworkHeader(name: "Authorization", value: "auth-secret"),
            ShaarNetworkHeader(name: "Cookie", value: "cookie-secret"),
            ShaarNetworkHeader(name: "X-Trace", value: "trace-kept"),
          ])
      ],
      environment: ShaarReproEnvironment(
        url: target.url.absoluteString, shaarVersion: "test", engineVersion: "fixture",
        operatingSystem: "macOS", userAgent: "Fixture/1", viewportWidth: 1040,
        viewportHeight: 620))
  }

  @Test func archiveRedactsHeadersAndFormValues() throws {
    let files = try ShaarReproBundle.files(for: fixture(), target: target)
    #expect(
      files.keys.sorted() == [
        "console.json", "dom.json", "manifest.json", "network.har", "page.mp4",
      ])
    let dom = String(decoding: files["dom.json"]!, as: UTF8.self)
    let har = String(decoding: files["network.har"]!, as: UTF8.self)
    #expect(!dom.contains("form-secret"))
    #expect(!dom.contains("attribute-secret"))
    #expect(dom.contains("Safe text"))
    #expect(!har.contains("auth-secret"))
    #expect(!har.contains("cookie-secret"))
    #expect(har.contains("trace-kept"))
  }

  @Test func savesAndOpensLocalBundle() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try await ShaarReproBundle.save(fixture(), target: target, directory: directory)
    #expect(file.pathExtension == "shaarrepro")
    let manifest = try await ShaarReproBundle.readManifest(at: file)
    #expect(manifest.durationSeconds == 24)
    #expect(manifest.consoleCount == 1)
    #expect(manifest.networkCount == 1)
    let contents = try await ShaarReproBundle.read(at: file)
    #expect(contents.console.first?.message == "Fixture warning")
    #expect(contents.network.first?.request.url == "https://example.com/api")
    #expect(contents.dom.children.first?.text == "[redacted]")
    #expect(contents.videoMP4 == fixture().videoMP4)
  }

  @Test func fixtureTransportCreatesBundleThroughShellModel() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = ShaarReproModel(
      target: target, transport: ShaarReproFixtureTransport(snapshot: fixture()))
    #expect(model.available)
    let file = try #require(await model.capture(to: directory))
    #expect(file.pathExtension == "shaarrepro")
    #expect(model.viewerManifest?.consoleCount == 1)
    #expect(model.viewerManifest?.networkCount == 1)
    #expect(model.viewerContents?.console.first?.message == "Fixture warning")
    let video = try #require(model.videoURL)
    #expect(
      try FileManager.default.attributesOfItem(atPath: video.path)[.posixPermissions] as? Int
        == 0o600)
    #expect(model.failure == nil)
    model.updateTarget(
      SiteControlTarget(
        tabID: UUID(), profileID: target.profileID, url: target.url))
    #expect(model.viewerContents == nil)
    #expect(!FileManager.default.fileExists(atPath: video.path))
  }

  @Test func productionTransportKeepsCaptureUnavailable() async {
    let model = ShaarReproModel(target: target)
    #expect(!model.available)
    #expect(await model.capture(to: FileManager.default.temporaryDirectory) == nil)
  }

  @Test func captureRejectsMismatchedTabAndUnboundedVideo() throws {
    let other = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://other.example/")!)
    #expect(throws: Error.self) { try ShaarReproBundle.files(for: fixture(), target: other) }
  }

  @Test func harMergesNetworkPhasesIntoOneRequest() throws {
    let id = UUID().uuidString
    let base = fixture()
    let capture = ShaarReproCapture(
      videoMP4: base.videoMP4, durationSeconds: base.durationSeconds,
      dom: base.dom, console: base.console,
      network: [
        ShaarNetworkEvent(
          id: UUID(), method: "GET", url: "https://example.com/api", status: nil,
          requestID: id, phase: .request, time: 1),
        ShaarNetworkEvent(
          id: UUID(), method: "", url: "", status: 200,
          requestID: id, phase: .response, time: 1.2),
        ShaarNetworkEvent(
          id: UUID(), method: "", url: "", status: nil,
          requestID: id, phase: .finished, time: 1.5),
      ], environment: base.environment)
    let files = try ShaarReproBundle.files(for: capture, target: target)
    let har = try #require(
      JSONSerialization.jsonObject(with: files["network.har"]!)
        as? [String: Any])
    let log = try #require(har["log"] as? [String: Any])
    let entries = try #require(log["entries"] as? [[String: Any]])
    #expect(entries.count == 1)
    #expect((entries[0]["request"] as? [String: Any])?["method"] as? String == "GET")
    #expect((entries[0]["response"] as? [String: Any])?["status"] as? Int == 200)
  }
}

private struct ShaarReproFixtureTransport: ShaarReproTransport {
  let available = true
  let snapshot: ShaarReproCapture

  func capture(for target: SiteControlTarget, seconds: Int) async throws -> ShaarReproCapture {
    #expect(seconds == 30)
    #expect(snapshot.environment.url == target.url.absoluteString)
    return snapshot
  }
}
