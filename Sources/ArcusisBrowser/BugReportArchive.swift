// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum BugReportArchive {
  static let scope = """
    This report contains a viewport screenshot, recent page console messages, metadata, and a
    bounded page-level HAR built from resource timing and instrumented fetch/XMLHttpRequest calls.
    Capture starts when page tools are enabled and continues across navigation while they stay open; buffered resource timing from the current navigation is also included. Response bodies, browser-generated request headers,
    cross-origin headers/timings without permission, workers, WebSockets, and other frames may be
    unavailable. Unknown methods use UNKNOWN and unknown timing phases use -1. Console messages and screenshot content are not
    redacted. Nothing was uploaded.
    """

  static func har(snapshot: [String: Any], includeSensitiveHeaders: Bool, version: String)
    -> [String: Any]
  {
    let origin = snapshot["timeOrigin"] as? Double ?? 0
    let calls = Array((snapshot["network"] as? [[String: Any]] ?? []).suffix(200))
    var used = Set<Int>()
    var entries: [[String: Any]] = []
    for resource in (snapshot["resources"] as? [[String: Any]] ?? []).suffix(1001) {
      let url = resource["url"] as? String ?? ""
      let start = resource["start"] as? Double ?? 0
      let match = calls.indices.filter {
        !used.contains($0) && calls[$0]["url"] as? String == url
          && abs((calls[$0]["start"] as? Double ?? 0) - start) <= 25
      }
      .min {
        abs((calls[$0]["start"] as? Double ?? 0) - start)
          < abs((calls[$1]["start"] as? Double ?? 0) - start)
      }
      if let match { used.insert(match) }
      entries.append(
        entry(
          resource: resource, call: match.map { calls[$0] }, origin: origin,
          includeSensitive: includeSensitiveHeaders))
    }
    for index in calls.indices where !used.contains(index) {
      let call = calls[index]
      let start = call["start"] as? Double ?? 0
      entries.append(
        entry(
          resource: [
            "url": call["url"] as? String ?? "", "start": start,
            "duration": max(0, (call["end"] as? Double ?? start) - start),
          ], call: call,
          origin: origin, includeSensitive: includeSensitiveHeaders))
    }
    return [
      "log": [
        "version": "1.2", "creator": ["name": "Shaar", "version": version],
        "entries": entries, "_captureScope": scope,
        "_sensitiveHeadersIncluded": includeSensitiveHeaders,
      ]
    ]
  }

  static func filteredHeaders(_ value: Any?, includeSensitive: Bool) -> [[String: String]] {
    let sensitive: Set<String> = [
      "cookie", "cookie2", "set-cookie", "set-cookie2", "authorization", "proxy-authorization",
    ]
    return (value as? [[String: Any]] ?? []).prefix(24).compactMap { row in
      guard let name = row["name"] as? String, let value = row["value"] as? String else {
        return nil
      }
      let hidden =
        !includeSensitive
        && sensitive.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      return [
        "name": String(name.prefix(128)),
        "value": hidden ? "[redacted]" : String(value.prefix(512)),
      ]
    }
  }

  private static func entry(
    resource: [String: Any], call: [String: Any]?, origin: Double, includeSensitive: Bool
  ) -> [String: Any] {
    func number(_ key: String) -> Double {
      guard let value = resource[key] as? Double, value.isFinite, value >= 0 else { return 0 }
      return value
    }
    let url = String((resource["url"] as? String ?? "").prefix(8192))
    let started = (origin + number("start")) / 1000
    let timestamp = started.isFinite && started >= 0 && started <= 253_402_300_799 ? started : 0
    let duration = number("duration")
    let query =
      URLComponents(string: url)?.queryItems?.map { ["name": $0.name, "value": $0.value ?? ""] }
      ?? []
    return [
      "startedDateTime": ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: timestamp)),
      "time": duration,
      "request": [
        "method": call?["method"] as? String ?? "UNKNOWN", "url": url, "httpVersion": "",
        "headers": filteredHeaders(call?["headers"], includeSensitive: includeSensitive),
        "queryString": query,
        "cookies": [], "headersSize": -1, "bodySize": -1,
      ],
      "response": [
        "status": call?["status"] as? Int ?? Int(min(999, number("status"))), "statusText": "",
        "httpVersion": "",
        "headers": filteredHeaders(call?["responseHeaders"], includeSensitive: includeSensitive),
        "cookies": [],
        "content": ["size": number("decoded"), "mimeType": ""], "redirectURL": "",
        "headersSize": -1, "bodySize": number("encoded"),
      ],
      "cache": [:], "timings": ["send": -1, "wait": -1, "receive": -1],
      "_transferSize": number("transfer"),
      "_initiator": resource["initiator"] as? String ?? "script",
      "_error": call?["error"] as? String ?? "",
      "_timingSource": resource["initiator"] == nil ? "instrumented-call" : "page-resource-timing",
    ]
  }

  /// Files and member names are browser-owned constants; no page-controlled paths enter ditto.
  static func save(files: [String: Data], directory: URL) async throws -> URL {
    try await Task.detached(priority: .utility) {
      let manager = FileManager.default
      guard files.values.reduce(0, { $0 + $1.count }) <= 64 * 1024 * 1024,
        files.keys.allSatisfy({ !$0.contains("/") && !$0.contains("..") && !$0.isEmpty })
      else { throw DeveloperModeFailure("The report exceeds its supported size.") }
      let id = UUID().uuidString
      let staging = manager.temporaryDirectory.appending(path: "shaar-bug-report-" + id)
      let partial = directory.appending(path: ".Shaar-Bug-Report-" + id + ".zip")
      let output = directory.appending(path: "Shaar-Bug-Report-" + id + ".zip")
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      try manager.createDirectory(
        at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer {
        try? manager.removeItem(at: staging)
        try? manager.removeItem(at: partial)
      }
      for (name, data) in files {
        let file = staging.appending(path: name)
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      }
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/ditto")
      process.arguments = ["-c", "-k", staging.path, partial.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw DeveloperModeFailure("The bug report could not be archived.")
      }
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
      try manager.moveItem(at: partial, to: output)
      return output.standardizedFileURL.resolvingSymlinksInPath()
    }.value
  }
}
