// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarSpotlightConsoleTransport: ShaarLocalConsoleTransport {
  let sourceID = "spotlight"
  let origin: ShaarConsoleEvent.Origin = .spotlight
  let port: Int

  init(port: Int = 8969) { self.port = port }

  static func endpoint(for target: SiteControlTarget, port: Int) -> URL? {
    guard DevelopmentModePreference.isEnabled,
      target.url.scheme?.lowercased() == "http",
      let host = target.url.host()?.lowercased(),
      ["localhost", "127.0.0.1", "::1"].contains(host),
      (1...65_535).contains(port)
    else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port
    components.path = "/stream"
    components.queryItems = [URLQueryItem(name: "client", value: "shaar")]
    return components.url
  }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarLocalConsoleMessage> {
    guard let endpoint = Self.endpoint(for: target, port: port) else {
      return AsyncStream { $0.finish() }
    }
    return AsyncStream { continuation in
      let task = Task { await stream(endpoint: endpoint, continuation: continuation) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func stream(
    endpoint: URL, continuation: AsyncStream<ShaarLocalConsoleMessage>.Continuation
  ) async {
    var lastEventID: String?
    while !Task.isCancelled {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 5
      configuration.timeoutIntervalForResource = 3_600
      let session = URLSession(
        configuration: configuration, delegate: ShaarNoRedirects(), delegateQueue: nil)
      do {
        var request = URLRequest(url: endpoint)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
          http.statusCode == 200,
          http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true
        else { throw URLError(.badServerResponse) }
        continuation.yield(.available)
        var frameBytes = Data()
        for try await byte in bytes {
          if Task.isCancelled { break }
          frameBytes.append(byte)
          if frameBytes.count > 128_000 { frameBytes.removeAll(keepingCapacity: true) }
          guard Self.isFrameEnd(frameBytes) else { continue }
          let frame = SpotlightSSEFrame(data: frameBytes)
          if frame.id == nil || frame.id != lastEventID {
            for event in Self.events(from: frame) { continuation.yield(.event(event)) }
            if let id = frame.id { lastEventID = id }
          }
          frameBytes.removeAll(keepingCapacity: true)
        }
      } catch is CancellationError {
        session.invalidateAndCancel()
        break
      } catch {
        // The sidecar is optional and may start after the page opens.
      }
      session.invalidateAndCancel()
      continuation.yield(.unavailable)
      do { try await Task.sleep(for: .seconds(2)) } catch { break }
    }
    continuation.finish()
  }

  private static func isFrameEnd(_ bytes: Data) -> Bool {
    bytes.suffix(2).elementsEqual([10, 10])
      || bytes.suffix(4).elementsEqual([13, 10, 13, 10])
  }

  private static func events(from frame: SpotlightSSEFrame) -> [ShaarConsoleEvent] {
    guard frame.kind.hasPrefix("application/x-sentry-envelope"),
      frame.data.count <= 128_000,
      let data = frame.data.data(using: .utf8),
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [Any],
      envelope.count == 2,
      let items = envelope[1] as? [[Any]]
    else { return [] }
    return items.prefix(80).flatMap { item -> [ShaarConsoleEvent] in
      guard item.count == 2,
        let header = item[0] as? [String: Any],
        let payload = item[1] as? [String: Any],
        let type = header["type"] as? String
      else { return [] }
      switch type {
      case "log":
        let rows = payload["items"] as? [[String: Any]] ?? []
        return rows.prefix(80).compactMap { row in
          guard let body = row["body"] as? String else { return nil }
          let severity = row["severity_number"] as? Int ?? 0
          return consoleEvent(body, level: level(for: severity))
        }
      case "event", "error":
        let values = (payload["exception"] as? [String: Any])?["values"] as? [[String: Any]]
        let message =
          values?.first?["value"] as? String
          ?? payload["message"] as? String
          ?? (payload["logentry"] as? [String: Any])?["formatted"] as? String
        guard let message else { return [] }
        let level: ShaarConsoleEvent.Level =
          payload["level"] as? String == "warning" ? .warning : .error
        return [consoleEvent(message, level: level)]
      default: return []
      }
    }
  }

  private static func level(for severity: Int) -> ShaarConsoleEvent.Level {
    if severity >= 17 { return .error }
    if severity >= 13 { return .warning }
    return .log
  }

  private static func consoleEvent(
    _ message: String, level: ShaarConsoleEvent.Level
  ) -> ShaarConsoleEvent {
    ShaarConsoleEvent(
      id: UUID(), level: level, message: String(message.prefix(4_096)),
      source: nil, origin: .spotlight)
  }
}

private struct SpotlightSSEFrame {
  var id: String?
  var kind = ""
  var data = ""

  init(data bytes: Data) {
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
      append(String(line).trimmingCharacters(in: .newlines))
    }
  }

  mutating func append(_ line: String) {
    if line.hasPrefix("id:") {
      id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("event:") {
      kind = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("data:") && data.count <= 128_000 {
      if !data.isEmpty { data += "\n" }
      data += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
  }
}
