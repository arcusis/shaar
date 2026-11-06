// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

struct ShaarReproDOMNode: Codable, Equatable, Sendable {
  let tag: String
  let text: String
  let attributes: [String: String]
  let children: [Self]

  /// Form contents stay out of the archive even when a fixture supplies them.
  func redacted(depth: Int = 0) -> Self {
    let editability = attributes["contenteditable"]?.lowercased()
    let editable = editability.map { ["", "true", "plaintext-only"].contains($0) } ?? false
    let form =
      ["form", "input", "textarea", "select", "option"].contains(tag.lowercased())
      || editable
    let safeAttributes = attributes.filter { key, _ in
      !form && !["value", "defaultvalue", "checked", "selected"].contains(key.lowercased())
        && !key.lowercased().hasPrefix("on")
    }
    return Self(
      tag: String(tag.prefix(64)), text: form ? "[redacted]" : String(text.prefix(4096)),
      attributes: Dictionary(
        uniqueKeysWithValues: safeAttributes.prefix(100).map {
          ($0.key, String($0.value.prefix(4096)))
        }),
      children: form || depth >= 32
        ? []
        : Array(children.prefix(500)).map {
          $0.redacted(depth: depth + 1)
        })
  }
}

struct ShaarReproEnvironment: Codable, Equatable, Sendable {
  let url: String
  let shaarVersion: String
  let engineVersion: String
  let operatingSystem: String
  let userAgent: String
  let viewportWidth: Int
  let viewportHeight: Int

  func redacted() -> Self {
    Self(
      url: ShaarReproRedaction.url(url), shaarVersion: shaarVersion,
      engineVersion: engineVersion, operatingSystem: operatingSystem,
      userAgent: userAgent, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
  }
}

private enum ShaarReproRedaction {
  static func url(_ raw: String) -> String {
    guard var components = URLComponents(string: raw) else { return "[redacted URL]" }
    components.user = nil
    components.password = nil
    components.fragment = nil
    components.queryItems = components.queryItems?.map { item in
      URLQueryItem(name: item.name, value: item.value.map { _ in "[redacted]" })
    }
    return components.string ?? "[redacted URL]"
  }
}

struct ShaarReproManifest: Codable, Sendable {
  let schemaVersion: Int
  let durationSeconds: Int
  let createdAt: String
  let consoleCount: Int
  let networkCount: Int
  let environment: ShaarReproEnvironment
  let redaction: String
}

struct ShaarReproConsoleRow: Codable, Sendable {
  let level: String
  let message: String
  let source: String
}

struct ShaarReproHAR: Decodable, Sendable {
  struct Log: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
      struct Request: Decodable, Sendable {
        let method: String
        let url: String
      }
      struct Response: Decodable, Sendable { let status: Int }
      let startedDateTime: String
      let time: Double
      let request: Request
      let response: Response
    }
    let entries: [Entry]
  }
  let log: Log
}

struct ShaarReproContents: Sendable {
  let manifest: ShaarReproManifest
  let console: [ShaarReproConsoleRow]
  let network: [ShaarReproHAR.Log.Entry]
  let dom: ShaarReproDOMNode
  let videoMP4: Data
}

struct ShaarReproCapture {
  let videoMP4: Data
  let durationSeconds: Int
  let dom: ShaarReproDOMNode
  let console: [ShaarConsoleEvent]
  let network: [ShaarNetworkEvent]
  let environment: ShaarReproEnvironment
}

@MainActor protocol ShaarReproTransport {
  var available: Bool { get }
  func capture(for target: SiteControlTarget, seconds: Int) async throws -> ShaarReproCapture
}

private struct ShaarReproUnavailable: LocalizedError {
  var errorDescription: String? { ShellL10n.string("Repro capture needs engine support") }
}

struct ShaarReproPendingTransport: ShaarReproTransport {
  let available = false
  func capture(for target: SiteControlTarget, seconds: Int) async throws -> ShaarReproCapture {
    throw ShaarReproUnavailable()
  }
}

@MainActor enum ShaarReproBundle {
  nonisolated static let seconds = 30
  static let maxVideoBytes = 48 * 1024 * 1024

  static func files(for capture: ShaarReproCapture, target: SiteControlTarget) throws
    -> [String: Data]
  {
    guard (1...seconds).contains(capture.durationSeconds),
      capture.videoMP4.count <= maxVideoBytes,
      capture.videoMP4.count >= 12,
      capture.videoMP4[4..<8].elementsEqual(Data("ftyp".utf8)),
      capture.environment.url == target.url.absoluteString
    else { throw ShaarReproUnavailable() }
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
    let console = capture.console.suffix(2_000).map { event in
      [
        "level": event.level.rawValue, "message": String(event.message.prefix(4096)),
        "source": String((event.source ?? "").prefix(1024)),
      ]
    }
    let requests = ShaarNetworkModel().requests(
      from: capture.network.suffix(2_000).map { .network($0) })
    let har = har(requests: requests, version: capture.environment.shaarVersion)
    let manifest = ShaarReproManifest(
      schemaVersion: 1, durationSeconds: capture.durationSeconds,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      consoleCount: console.count, networkCount: requests.count,
      environment: capture.environment.redacted(),
      redaction:
        "Cookie and authorization headers, URL query values and credentials, and DOM form values omitted. Video and console may contain visible sensitive text."
    )
    return [
      "manifest.json": try JSONEncoder().encode(manifest),
      "console.json": try JSONSerialization.data(withJSONObject: console, options: options),
      "network.har": try JSONSerialization.data(withJSONObject: har, options: options),
      "dom.json": try JSONEncoder().encode(capture.dom.redacted()),
      "page.mp4": capture.videoMP4,
    ]
  }

  private static func har(requests: [ShaarNetworkRequest], version: String) -> [String: Any] {
    let latest =
      requests.compactMap { request -> Double? in
        let time = request.completedAt ?? request.startedAt
        return time.isFinite ? time : nil
      }.max() ?? 0
    let now = Date()
    let entries: [[String: Any]] = requests.map { request in
      let start = request.startedAt.isFinite ? request.startedAt : latest
      let date = now.addingTimeInterval(min(0, max(-30, start - latest)))
      let duration = request.duration.map { min(30_000, $0 * 1_000) } ?? 0
      let url = ShaarReproRedaction.url(String(request.url.prefix(8192)))
      return [
        "startedDateTime": ISO8601DateFormatter().string(from: date),
        "time": duration,
        "request": [
          "method": String(request.method.prefix(32)), "url": url, "httpVersion": "",
          "headers": redactedHeaders(request.requestHeaders),
          "queryString": URLComponents(string: url)?.queryItems?.map {
            ["name": $0.name, "value": $0.value ?? ""]
          } ?? [],
          "cookies": [], "headersSize": -1, "bodySize": -1,
        ] as [String: Any],
        "response": [
          "status": request.status ?? 0, "statusText": "", "httpVersion": "",
          "headers": redactedHeaders(request.responseHeaders), "cookies": [],
          "content": [
            "size": request.encodedBytes ?? 0,
            "mimeType": request.mimeType ?? "",
          ],
          "redirectURL": "", "headersSize": -1, "bodySize": request.encodedBytes ?? -1,
        ] as [String: Any],
        "cache": [:], "timings": ["send": -1, "wait": -1, "receive": -1],
        "_timingSource": "shaar-devtools-stream",
      ]
    }
    return [
      "log": [
        "version": "1.2", "creator": ["name": "Shaar", "version": version],
        "entries": entries,
        "_captureScope":
          "Tab-scoped DevTools events; absolute times are anchored at export. Response bodies are omitted.",
        "_sensitiveHeadersIncluded": false,
      ]
    ]
  }

  private static func redactedHeaders(_ rows: [ShaarNetworkHeader]) -> [[String: String]] {
    let urlHeaders: Set<String> = [
      "referer", "referrer", "location", "content-location", "refresh", "link",
    ]
    return BugReportArchive.filteredHeaders(
      rows.map { ["name": $0.name, "value": $0.value] }, includeSensitive: false
    ).map { row in
      guard let name = row["name"],
        urlHeaders.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      else { return row }
      var redacted = row
      redacted["value"] = "[redacted]"
      return redacted
    }
  }

  static func save(
    _ capture: ShaarReproCapture, target: SiteControlTarget, directory: URL
  ) async throws -> URL {
    let files = try files(for: capture, target: target)
    return try await BugReportArchive.save(
      files: files, directory: directory, name: "Shaar-Repro", fileExtension: "shaarrepro")
  }

  static func readManifest(at url: URL) async throws -> ShaarReproManifest {
    guard url.isFileURL, url.pathExtension == "shaarrepro",
      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
      size <= 64 * 1024 * 1024
    else { throw ShaarReproUnavailable() }
    let data = try await readEntry(at: url, name: "manifest.json", limit: 65_536)
    let manifest = try JSONDecoder().decode(ShaarReproManifest.self, from: data)
    guard manifest.schemaVersion == 1,
      (1...seconds).contains(manifest.durationSeconds),
      (0...2_000).contains(manifest.consoleCount),
      (0...2_000).contains(manifest.networkCount),
      URL(string: manifest.environment.url) != nil
    else { throw ShaarReproUnavailable() }
    return manifest
  }

  static func read(at url: URL) async throws -> ShaarReproContents {
    let manifest = try await readManifest(at: url)
    let consoleData = try await readEntry(at: url, name: "console.json", limit: 4 * 1024 * 1024)
    let harData = try await readEntry(at: url, name: "network.har", limit: 12 * 1024 * 1024)
    let domData = try await readEntry(at: url, name: "dom.json", limit: 16 * 1024 * 1024)
    let video = try await readEntry(at: url, name: "page.mp4", limit: maxVideoBytes)
    let console = try JSONDecoder().decode([ShaarReproConsoleRow].self, from: consoleData)
    let har = try JSONDecoder().decode(ShaarReproHAR.self, from: harData)
    let dom = try JSONDecoder().decode(ShaarReproDOMNode.self, from: domData)
    guard console.count == manifest.consoleCount,
      har.log.entries.count == manifest.networkCount,
      video.count >= 12, video[4..<8].elementsEqual(Data("ftyp".utf8))
    else { throw ShaarReproUnavailable() }
    return ShaarReproContents(
      manifest: manifest, console: console, network: har.log.entries,
      dom: dom, videoMP4: video)
  }

  private static func readEntry(at url: URL, name: String, limit: Int) async throws -> Data {
    try await Task.detached(priority: .utility) {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(filePath: "/usr/bin/unzip")
      process.arguments = ["-p", url.path, name]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      var data = Data()
      while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
        data.append(chunk)
        if data.count > limit {
          process.terminate()
          process.waitUntilExit()
          throw ShaarReproUnavailable()
        }
      }
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw ShaarReproUnavailable() }
      return data
    }.value
  }

  static func materializeVideo(_ data: Data) async throws -> URL {
    try await Task.detached(priority: .utility) {
      let manager = FileManager.default
      let directory = manager.temporaryDirectory.appending(
        path: "shaar-repro-viewer-" + UUID().uuidString)
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      do {
        let file = directory.appending(path: "page.mp4")
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
      } catch {
        try? manager.removeItem(at: directory)
        throw error
      }
    }.value
  }
}

@MainActor @Observable final class ShaarReproModel {
  @ObservationIgnored let history = ShaarReproHistory()
  private(set) var target: SiteControlTarget
  private(set) var busy = false
  private(set) var savedURL: URL?
  private(set) var viewerManifest: ShaarReproManifest?
  private(set) var viewerContents: ShaarReproContents?
  private(set) var videoURL: URL?
  var failure: String?
  @ObservationIgnored private let transport: any ShaarReproTransport
  @ObservationIgnored private var viewerGeneration = 0

  init(target: SiteControlTarget, transport: any ShaarReproTransport = ShaarReproPendingTransport())
  {
    self.target = target
    self.transport = transport
  }

  var available: Bool { transport.available }

  func updateTarget(_ target: SiteControlTarget, committed: Bool = false) {
    guard self.target != target || committed else { return }
    self.target = target
    clearViewer()
    failure = nil
  }

  func capture(to directory: URL) async -> URL? {
    guard available, !busy else { return nil }
    busy = true
    failure = nil
    defer { busy = false }
    let target = target
    do {
      let captured = try await transport.capture(for: target, seconds: ShaarReproBundle.seconds)
      let capture: ShaarReproCapture
      if history.isActive {
        let recent = history.snapshot()
        capture = ShaarReproCapture(
          videoMP4: captured.videoMP4, durationSeconds: captured.durationSeconds,
          dom: captured.dom, console: recent.console, network: recent.network,
          environment: captured.environment)
      } else {
        capture = captured
      }
      guard self.target == target else { throw CancellationError() }
      let file = try await ShaarReproBundle.save(capture, target: target, directory: directory)
      guard self.target == target else {
        try? FileManager.default.removeItem(at: file)
        throw CancellationError()
      }
      await open(file)
      guard viewerContents != nil else { return nil }
      return file
    } catch {
      failure = error.localizedDescription
      return nil
    }
  }

  func open(_ url: URL) async {
    failure = nil
    clearViewer()
    let generation = viewerGeneration
    do {
      let contents = try await ShaarReproBundle.read(at: url)
      let video = try await ShaarReproBundle.materializeVideo(contents.videoMP4)
      guard generation == viewerGeneration else {
        try? FileManager.default.removeItem(at: video.deletingLastPathComponent())
        return
      }
      viewerContents = contents
      viewerManifest = contents.manifest
      videoURL = video
      savedURL = url
    } catch {
      failure = error.localizedDescription
    }
  }

  private func clearViewer() {
    viewerGeneration += 1
    if let videoURL {
      try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent())
    }
    videoURL = nil
    viewerContents = nil
    viewerManifest = nil
    savedURL = nil
  }

  isolated deinit {
    if let videoURL {
      try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent())
    }
  }
}
