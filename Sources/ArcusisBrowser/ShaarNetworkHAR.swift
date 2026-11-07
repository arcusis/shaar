// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

enum ShaarNetworkHeaderRedaction {
  private static let sensitive: Set<String> = [
    "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key",
  ]

  static func value(name: String, value: String) -> String {
    sensitive.contains(name.lowercased()) ? "[redacted]" : value
  }

  static func value(_ header: ShaarNetworkHeader) -> String {
    value(name: header.name, value: header.value)
  }
}

struct ShaarStoredResponseBody: Equatable, Sendable {
  var body: String
  var base64Encoded: Bool
}

enum ShaarNetworkBodyError: LocalizedError {
  case unavailable

  var errorDescription: String? { "The response body is unavailable." }
}

enum ShaarNetworkBodyPresentation {
  static func apply(
    _ stored: ShaarStoredResponseBody, mime: String?
  ) -> (text: String, image: Data?, binary: Bool) {
    guard stored.base64Encoded else { return (stored.body, nil, false) }
    guard let data = Data(base64Encoded: stored.body) else {
      return (stored.body, nil, false)
    }
    if mime?.lowercased().hasPrefix("image/") == true {
      return ("", data, true)
    }
    if let text = String(data: data, encoding: .utf8) {
      return (text, nil, false)
    }
    return ("", nil, true)
  }
}

enum ShaarNetworkHAR {
  static let bodyLimit = 65_536

  static func document(requests: [ShaarNetworkRequest]) -> Data {
    let root: [String: Any] = [
      "log": [
        "version": "1.2",
        "creator": ["name": "Shaar", "version": "1"],
        "entries": requests.map(entry),
      ]
    ]
    return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
  }

  private static func entry(_ row: ShaarNetworkRequest) -> [String: Any] {
    var request: [String: Any] = [
      "method": row.method,
      "url": row.url,
      "headers": headers(row.requestHeaders),
    ]
    if let payload = bounded(row.payload) {
      request["postData"] = ["mimeType": row.mimeType ?? "", "text": payload]
    }
    var content: [String: Any] = ["mimeType": row.mimeType ?? ""]
    if row.responseIsBinary, let data = row.previewData {
      content["encoding"] = "base64"
      content["text"] = String(data.base64EncodedString().prefix(bodyLimit))
    } else if let body = bounded(row.responseBody) {
      content["text"] = body
    }
    let response: [String: Any] = [
      "status": row.status ?? 0,
      "statusText": "",
      "headers": headers(row.responseHeaders),
      "content": content,
    ]
    let milliseconds = (row.duration ?? 0) * 1_000
    return [
      "startedDateTime": started(row.startedAt),
      "time": milliseconds,
      "request": request,
      "response": response,
      "cache": [String: String](),
      "timings": ["wait": milliseconds, "receive": 0],
    ]
  }

  private static func headers(_ headers: [ShaarNetworkHeader]) -> [[String: String]] {
    headers.prefix(64).map { header in
      ["name": header.name, "value": ShaarNetworkHeaderRedaction.value(header)]
    }
  }

  private static func bounded(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return String(text.prefix(bodyLimit))
  }

  private static func started(_ time: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: time))
  }
}
