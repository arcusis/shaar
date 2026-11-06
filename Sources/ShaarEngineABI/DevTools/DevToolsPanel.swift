// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Fixed IDs shared with shaar_devtools_panel_event_id. The protocol method
/// string never crosses the engine ABI.
public enum ShaarDevToolsPanelEventID: Int, CaseIterable, Sendable {
  case consoleAPICalled = 1
  case exceptionThrown = 2
  case logEntryAdded = 3
  case requestWillBeSent = 4
  case responseReceived = 5
  case loadingFinished = 6
  case loadingFailed = 7
  case dataReceived = 8
  case pageLifecycle = 9
  case performanceMetrics = 10
  case eventsDropped = 11
}

public struct ShaarDevToolsPanelMetric: Equatable, Sendable {
  public let name: String
  public let value: Double
}

/// A deliberately small projection of a CDP event. Nil means the field does
/// not apply to that event ID. Panel data is live-only and must not be saved.
public struct ShaarDevToolsPanelData: Equatable, Sendable {
  public let text: String?
  public let level: String?
  public let requestID: String?
  public let url: String?
  public let method: String?
  public let status: Double?
  public let mimeType: String?
  public let encodedBytes: Double?
  public let name: String?
  public let metrics: [ShaarDevToolsPanelMetric]?
  public let droppedCount: UInt32?
  public let truncated: Bool
}

public struct ShaarDevToolsPanelEvent: Equatable, Sendable {
  public let sequence: UInt64
  public let leaseID: UInt32
  public let id: ShaarDevToolsPanelEventID
  public let data: ShaarDevToolsPanelData
}

public struct ShaarDevToolsResponseBody: Equatable, Sendable {
  public let body: String
  public let base64Encoded: Bool

  public static func decode(_ data: Data) -> Self? {
    guard data.count <= 1_100_000,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["schemaVersion", "body", "base64Encoded"],
      object["schemaVersion"] as? Int == 1,
      let body = object["body"] as? String,
      body.utf8.count <= 1_048_576,
      let encoded = object["base64Encoded"] as? Bool
    else { return nil }
    return Self(body: body, base64Encoded: encoded)
  }
}

public enum ShaarDevToolsPanelEventRouter {
  public static func decode(
    _ event: ShaarCopiedEvent, scope: ShaarNavigationScope,
    windowID: String, tabID: String, leaseID: UInt32,
    afterSequence: UInt64 = 0
  ) -> ShaarDevToolsPanelEvent? {
    guard event.kind == 14, event.sequence > afterSequence,
      event.profileID == Data(scope.profileID.utf8),
      event.sessionID == Data((scope.sessionID ?? "").utf8),
      event.windowID == Data(windowID.utf8),
      event.tabID == Data(tabID.utf8),
      event.payloadJSON.count <= 32_768,
      let root = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      Set(root.keys) == ["schemaVersion", "kind", "eventID", "leaseID", "data"],
      root["schemaVersion"] as? Int == 1,
      root["kind"] as? String == "panelEvent",
      let rawID = root["eventID"] as? Int,
      let id = ShaarDevToolsPanelEventID(rawValue: rawID),
      root["leaseID"] as? UInt32 == leaseID,
      let fields = root["data"] as? [String: Any],
      let payload = decodeData(fields, for: id)
    else { return nil }
    return ShaarDevToolsPanelEvent(
      sequence: event.sequence, leaseID: leaseID, id: id, data: payload)
  }

  private static func decodeData(
    _ fields: [String: Any], for id: ShaarDevToolsPanelEventID
  ) -> ShaarDevToolsPanelData? {
    if id == .eventsDropped {
      guard Set(fields.keys) == ["count"],
        let count = fields["count"] as? Int,
        count > 0, let value = UInt32(exactly: count)
      else { return nil }
      return ShaarDevToolsPanelData(
        text: nil, level: nil, requestID: nil, url: nil, method: nil,
        status: nil, mimeType: nil, encodedBytes: nil, name: nil,
        metrics: nil, droppedCount: value, truncated: false)
    }
    guard let truncated = fields["truncated"] as? Bool,
      Set(fields.keys).isSubset(of: allowedKeys(for: id)),
      validString(fields["text"]), validString(fields["level"]),
      validString(fields["requestID"], limit: 128),
      validString(fields["url"]), validString(fields["method"]),
      validString(fields["mimeType"]), validString(fields["name"])
    else { return nil }
    let requestID = fields["requestID"] as? String
    if [.requestWillBeSent, .responseReceived, .loadingFinished,
        .loadingFailed, .dataReceived].contains(id) && (requestID?.isEmpty ?? true) {
      return nil
    }
    let status = fields["status"] as? Double
    let encodedBytes = fields["encodedBytes"] as? Double
    if fields["status"] != nil && (status == nil || !status!.isFinite) { return nil }
    if fields["encodedBytes"] != nil &&
      (encodedBytes == nil || !encodedBytes!.isFinite || encodedBytes! < 0) { return nil }
    let metrics: [ShaarDevToolsPanelMetric]?
    if let rawMetrics = fields["metrics"] {
      guard let entries = rawMetrics as? [[String: Any]], entries.count <= 32 else { return nil }
      var parsed: [ShaarDevToolsPanelMetric] = []
      for entry in entries {
        guard Set(entry.keys) == ["name", "value"],
          let name = entry["name"] as? String, name.utf8.count <= 4_096,
          let value = entry["value"] as? Double, value.isFinite
        else { return nil }
        parsed.append(ShaarDevToolsPanelMetric(name: name, value: value))
      }
      metrics = parsed
    } else {
      metrics = nil
    }
    return ShaarDevToolsPanelData(
      text: fields["text"] as? String, level: fields["level"] as? String,
      requestID: requestID, url: fields["url"] as? String,
      method: fields["method"] as? String, status: status,
      mimeType: fields["mimeType"] as? String, encodedBytes: encodedBytes,
      name: fields["name"] as? String, metrics: metrics,
      droppedCount: nil, truncated: truncated)
  }

  private static func allowedKeys(for id: ShaarDevToolsPanelEventID) -> Set<String> {
    var fields: Set<String> = ["truncated"]
    switch id {
    case .consoleAPICalled, .logEntryAdded: fields.formUnion(["text", "level"])
    case .exceptionThrown: fields.insert("text")
    case .requestWillBeSent: fields.formUnion(["requestID", "url", "method"])
    case .responseReceived: fields.formUnion(["requestID", "url", "status", "mimeType"])
    case .loadingFinished, .dataReceived: fields.formUnion(["requestID", "encodedBytes"])
    case .loadingFailed: fields.formUnion(["requestID", "text"])
    case .pageLifecycle: fields.insert("name")
    case .performanceMetrics: fields.insert("metrics")
    case .eventsDropped: break
    }
    return fields
  }

  private static func validString(_ value: Any?, limit: Int = 4_096) -> Bool {
    guard let value else { return true }
    guard let text = value as? String else { return false }
    return text.utf8.count <= limit
  }
}
