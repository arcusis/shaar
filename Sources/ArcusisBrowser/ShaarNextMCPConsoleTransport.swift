// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct ShaarNextMCPConsoleTransport: ShaarLocalConsoleTransport {
  let sourceID = "nextMCP"
  let origin: ShaarConsoleEvent.Origin = .server

  static func endpoint(for target: SiteControlTarget) -> URL? {
    guard DevelopmentModePreference.isEnabled,
      target.url.scheme?.lowercased() == "http",
      let host = target.url.host()?.lowercased(),
      ["localhost", "127.0.0.1", "::1"].contains(host)
    else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host == "::1" ? "::1" : "127.0.0.1"
    components.port = target.url.port
    components.path = "/_next/mcp"
    return components.url
  }

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarLocalConsoleMessage> {
    guard let endpoint = Self.endpoint(for: target) else {
      return AsyncStream { $0.finish() }
    }
    return AsyncStream { continuation in
      let task = Task {
        await run(endpoint: endpoint, continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(
    endpoint: URL, continuation: AsyncStream<ShaarLocalConsoleMessage>.Continuation
  ) async {
    do {
      let project = try await call("get_project_metadata", at: endpoint)
      guard let root = Self.projectRoot(from: project) else { throw URLError(.cannotParseResponse) }
      let logReply = try await call("get_logs", at: endpoint)
      guard let logURL = Self.logFile(from: logReply, within: root) else {
        throw URLError(.cannotParseResponse)
      }
      continuation.yield(.available)
      var logReader = ShaarLocalLogReader(file: logURL)
      var seenErrors = Set<String>()
      while !Task.isCancelled {
        for line in try logReader.readLines() {
          continuation.yield(.event(Self.event(line, level: .log)))
        }
        let errors = try await call("get_errors", at: endpoint)
        let currentErrors = Set(Self.errorMessages(from: errors))
        for message in currentErrors.sorted() where !seenErrors.contains(message) {
          continuation.yield(.event(Self.event(message, level: .error)))
        }
        seenErrors = currentErrors
        try await Task.sleep(for: .seconds(2))
      }
    } catch is CancellationError {
      // Closing the dock or changing tabs cancels this source.
    } catch {
      continuation.yield(.unavailable)
    }
    continuation.finish()
  }

  private func call(_ name: String, at endpoint: URL) async throws -> String {
    let payload: [String: Any] = [
      "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
      "params": ["name": name, "arguments": [:]],
    ]
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let data = try await ShaarLocalConsoleHTTP.data(for: request)
    return try Self.contentText(from: data)
  }

  private static func contentText(from data: Data) throws -> String {
    let body = String(decoding: data, as: UTF8.self)
    let jsonData: Data
    if body.hasPrefix("event:") || body.hasPrefix("data:") {
      guard let line = body.split(separator: "\n").last(where: { $0.hasPrefix("data:") }) else {
        throw URLError(.cannotParseResponse)
      }
      jsonData = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
    } else {
      jsonData = data
    }
    guard let reply = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
      reply["error"] == nil,
      let result = reply["result"] as? [String: Any],
      result["isError"] as? Bool != true,
      let content = result["content"] as? [[String: Any]],
      let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    else { throw URLError(.cannotParseResponse) }
    return String(text.prefix(64_000))
  }

  private static func projectRoot(from text: String) -> URL? {
    guard let data = text.data(using: .utf8),
      let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let path = metadata["projectPath"] as? String, path.hasPrefix("/")
    else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func logFile(from text: String, within root: URL) -> URL? {
    let path: String
    if let data = text.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let namedPath = (value["logFilePath"] ?? value["path"]) as? String
    {
      path = namedPath
    } else {
      path = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard path.hasPrefix("/"), path.hasSuffix("/logs/next-development.log") else { return nil }
    let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard file.path.hasPrefix(root.path + "/") else { return nil }
    return file
  }

  private static func errorMessages(from text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.localizedCaseInsensitiveContains("no errors") { return [] }
    if let data = trimmed.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data)
    {
      let rows =
        (decoded as? [[String: Any]])
        ?? ((decoded as? [String: Any])?["errors"] as? [[String: Any]]) ?? []
      if !rows.isEmpty {
        return rows.compactMap { $0["message"] as? String }.map { String($0.prefix(4_096)) }
      }
    }
    return [String(trimmed.prefix(4_096))]
  }

  private static func event(_ message: String, level: ShaarConsoleEvent.Level) -> ShaarConsoleEvent
  {
    ShaarConsoleEvent(
      id: UUID(), level: level, message: String(message.prefix(4_096)), source: nil,
      origin: .server)
  }
}
