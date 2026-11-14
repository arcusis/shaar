// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

private func panelInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

private func panelBoolean(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) == CFBooleanGetTypeID()
  else { return nil }
  return number.boolValue
}

private func panelNumber(_ value: Any?) -> Double? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
  else { return nil }
  return number.doubleValue
}

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
  case screencastFrame = 29
  case webSocketCreated = 31
  case webSocketHandshake = 32
  case webSocketFrameSent = 33
  case webSocketFrameReceived = 34
  case webSocketClosed = 35
}

public struct ShaarDevToolsPanelFrame: Equatable, Sendable {
  public let jpeg: Data
  public let sessionID: Int
}

public struct ShaarDevToolsPanelMetric: Equatable, Sendable {
  public let name: String
  public let value: Double
}

public struct ShaarDevToolsConsoleFrame: Equatable, Sendable {
  public let function: String
  public let source: String
}

public struct ShaarDevToolsPanelHeader: Equatable, Sendable {
  public let name: String
  public let value: String
}

/// A deliberately small projection of a CDP event. Nil means the field does
/// not apply to that event ID. Panel data is live-only and must not be saved.
public struct ShaarDevToolsPanelData: Equatable, Sendable {
  public let text: String?
  public let level: String?
  public let objectID: String?
  public let requestID: String?
  public let url: String?
  public let method: String?
  public let status: Double?
  public let opcode: Int?
  public let payload: String?
  public let mimeType: String?
  public let encodedBytes: Double?
  public let name: String?
  public let metrics: [ShaarDevToolsPanelMetric]?
  public let droppedCount: UInt32?
  public let frame: ShaarDevToolsPanelFrame?
  public let stack: [ShaarDevToolsConsoleFrame]
  public let requestHeaders: [ShaarDevToolsPanelHeader]
  public let responseHeaders: [ShaarDevToolsPanelHeader]
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
      panelInteger(object["schemaVersion"]) == 1,
      let body = object["body"] as? String,
      body.utf8.count <= 1_048_576,
      let encoded = panelBoolean(object["base64Encoded"])
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
      event.payloadJSON.count <= 384 * 1024,
      let root = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      Set(root.keys) == ["schemaVersion", "kind", "eventID", "leaseID", "data"],
      panelInteger(root["schemaVersion"]) == 1,
      root["kind"] as? String == "panelEvent",
      let rawID = panelInteger(root["eventID"]),
      let id = ShaarDevToolsPanelEventID(rawValue: rawID),
      id == .screencastFrame || event.payloadJSON.count <= 32_768,
      let rawLeaseID = panelInteger(root["leaseID"]), rawLeaseID >= 0,
      rawLeaseID <= Int(UInt32.max), UInt32(rawLeaseID) == leaseID,
      panelInteger(root["schemaVersion"]) == 1,
      root["kind"] as? String == "panelEvent",
      let rawID = panelInteger(root["eventID"]),
      let id = ShaarDevToolsPanelEventID(rawValue: rawID),
      id == .screencastFrame || event.payloadJSON.count <= 32_768,
      let rawLeaseID = panelInteger(root["leaseID"]),
      UInt32(exactly: rawLeaseID) == leaseID,
      let fields = root["data"] as? [String: Any],
      let payload = decodeData(fields, for: id)
    else { return nil }
    return ShaarDevToolsPanelEvent(
      sequence: event.sequence, leaseID: leaseID, id: id, data: payload)
  }

  private static func decodeData(
    _ fields: [String: Any], for id: ShaarDevToolsPanelEventID
  ) -> ShaarDevToolsPanelData? {
    if id == .screencastFrame {
      guard
        Set(fields.keys) == [
          "jpegBase64", "sessionID", "masked", "truncated",
        ], panelBoolean(fields["masked"]) == true,
        panelBoolean(fields["truncated"]) == false,
        let text = fields["jpegBase64"] as? String, text.utf8.count <= 350_000,
        let jpeg = Data(base64Encoded: text), jpeg.count <= 256 * 1024,
        jpeg.count >= 4, jpeg.starts(with: [0xFF, 0xD8]),
        jpeg.suffix(2).elementsEqual([0xFF, 0xD9]),
        let sessionID = panelInteger(fields["sessionID"]), sessionID > 0
      else { return nil }
      return ShaarDevToolsPanelData(
        text: nil, level: nil, objectID: nil, requestID: nil, url: nil, method: nil,
        status: nil, opcode: nil, payload: nil,
        mimeType: nil, encodedBytes: nil, name: nil,
        metrics: nil, droppedCount: nil,
        frame: ShaarDevToolsPanelFrame(jpeg: jpeg, sessionID: sessionID),
        stack: [], requestHeaders: [], responseHeaders: [], truncated: false)
    }
    if id == .eventsDropped {
      guard Set(fields.keys) == ["count"],
        let count = panelInteger(fields["count"]),
        count > 0, let value = UInt32(exactly: count)
      else { return nil }
      return ShaarDevToolsPanelData(
        text: nil, level: nil, objectID: nil, requestID: nil, url: nil, method: nil,
        status: nil, opcode: nil, payload: nil,
        mimeType: nil, encodedBytes: nil, name: nil,
        metrics: nil, droppedCount: value, frame: nil, stack: [],
        requestHeaders: [], responseHeaders: [], truncated: false)
    }
    guard let truncated = panelBoolean(fields["truncated"]),
      Set(fields.keys).isSubset(of: allowedKeys(for: id)),
      validString(fields["text"]), validString(fields["level"]),
      validString(fields["objectID"]),
      validString(fields["requestID"], limit: 128),
      validString(fields["url"]), validString(fields["method"]),
      validString(fields["payload"]),
      validString(fields["mimeType"]), validString(fields["name"])
    else { return nil }
    let requestID = fields["requestID"] as? String
    if [
      .requestWillBeSent, .responseReceived, .loadingFinished,
      .loadingFailed, .dataReceived, .webSocketCreated,
      .webSocketHandshake, .webSocketFrameSent, .webSocketFrameReceived,
      .webSocketClosed,
    ].contains(id) && (requestID?.isEmpty ?? true) {
      return nil
    }
    let status = panelNumber(fields["status"])
    let opcode = panelInteger(fields["opcode"])
    if fields["opcode"] != nil && (opcode == nil || !(0...15).contains(opcode!)) {
      return nil
    }
    if [.webSocketFrameSent, .webSocketFrameReceived].contains(id) && opcode == nil {
      return nil
    }
    let encodedBytes = panelNumber(fields["encodedBytes"])
    if fields["status"] != nil && (status == nil || !status!.isFinite) { return nil }
    if fields["encodedBytes"] != nil
      && (encodedBytes == nil || !encodedBytes!.isFinite || encodedBytes! < 0)
    {
      return nil
    }
    let metrics: [ShaarDevToolsPanelMetric]?
    if let rawMetrics = fields["metrics"] {
      guard let entries = rawMetrics as? [[String: Any]], entries.count <= 32 else { return nil }
      var parsed: [ShaarDevToolsPanelMetric] = []
      for entry in entries {
        guard Set(entry.keys) == ["name", "value"],
          let name = entry["name"] as? String, name.utf8.count <= 4_096,
          let value = panelNumber(entry["value"])
        else { return nil }
        parsed.append(ShaarDevToolsPanelMetric(name: name, value: value))
      }
      metrics = parsed
    } else {
      metrics = nil
    }
    guard let stack = consoleFrames(fields) else { return nil }
    guard let requestHeaders = headers(fields["requestHeaders"]),
      let responseHeaders = headers(fields["responseHeaders"])
    else { return nil }
    return ShaarDevToolsPanelData(
      text: fields["text"] as? String, level: fields["level"] as? String,
      objectID: fields["objectID"] as? String,
      requestID: requestID, url: fields["url"] as? String,
      method: fields["method"] as? String, status: status,
      opcode: opcode, payload: fields["payload"] as? String,
      mimeType: fields["mimeType"] as? String, encodedBytes: encodedBytes,
      name: fields["name"] as? String, metrics: metrics,
      droppedCount: nil, frame: nil, stack: stack,
      requestHeaders: requestHeaders, responseHeaders: responseHeaders,
      truncated: truncated)
  }

  private static func headers(_ raw: Any?) -> [ShaarDevToolsPanelHeader]? {
    guard let raw else { return [] }
    guard let entries = raw as? [[String: Any]], entries.count <= 64 else { return nil }
    var headers: [ShaarDevToolsPanelHeader] = []
    var totalBytes = 0
    for entry in entries {
      guard Set(entry.keys) == ["name", "value"],
        let name = entry["name"] as? String, !name.isEmpty,
        name.utf8.count <= 128,
        let value = entry["value"] as? String, value.utf8.count <= 1_024
      else { return nil }
      totalBytes += name.utf8.count + value.utf8.count
      guard totalBytes <= 16_384 else { return nil }
      headers.append(ShaarDevToolsPanelHeader(name: name, value: value))
    }
    return headers
  }

  private static func consoleFrames(
    _ fields: [String: Any]
  ) -> [ShaarDevToolsConsoleFrame]? {
    guard let raw = fields["stack"] else { return [] }
    guard let entries = raw as? [[String: Any]], entries.count <= 8 else { return nil }
    var frames: [ShaarDevToolsConsoleFrame] = []
    for entry in entries {
      guard Set(entry.keys) == ["function", "source"],
        let function = entry["function"] as? String, !function.isEmpty,
        function.utf8.count <= 128,
        let source = entry["source"] as? String, !source.isEmpty,
        source.utf8.count <= 512
      else { return nil }
      frames.append(ShaarDevToolsConsoleFrame(function: function, source: source))
    }
    return frames
  }

  private static func allowedKeys(for id: ShaarDevToolsPanelEventID) -> Set<String> {
    var fields: Set<String> = ["truncated"]
    switch id {
    case .consoleAPICalled: fields.formUnion(["text", "level", "stack", "objectID"])
    case .logEntryAdded: fields.formUnion(["text", "level", "stack"])
    case .exceptionThrown: fields.formUnion(["text", "stack"])
    case .requestWillBeSent:
      fields.formUnion(["requestID", "url", "method", "requestHeaders"])
    case .responseReceived:
      fields.formUnion(["requestID", "url", "status", "mimeType", "responseHeaders"])
    case .loadingFinished, .dataReceived: fields.formUnion(["requestID", "encodedBytes"])
    case .loadingFailed: fields.formUnion(["requestID", "text"])
    case .webSocketCreated: fields.formUnion(["requestID", "url"])
    case .webSocketHandshake: fields.formUnion(["requestID", "status"])
    case .webSocketFrameSent, .webSocketFrameReceived:
      fields.formUnion(["requestID", "opcode", "payload"])
    case .webSocketClosed: fields.insert("requestID")
    case .pageLifecycle: fields.insert("name")
    case .performanceMetrics: fields.insert("metrics")
    case .eventsDropped: break
    case .screencastFrame: break
    }
    return fields
  }

  private static func validString(_ value: Any?, limit: Int = 4_096) -> Bool {
    guard let value else { return true }
    guard let text = value as? String else { return false }
    return text.utf8.count <= limit
  }
}
