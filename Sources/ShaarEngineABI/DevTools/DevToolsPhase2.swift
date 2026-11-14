// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

private func phase2ReplyInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

private func phase2ReplyBoolean(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) == CFBooleanGetTypeID()
  else { return nil }
  return number.boolValue
}

/// Fixed commands within the tab-scoped DevTools panel lease. Cookies and
/// site-data clearing belong to the site-data adapter.
public enum ShaarDevToolsPhase2Command: Equatable, Sendable {
  case storageItems(local: Bool, skip: Int, count: Int)
  case storageSet(local: Bool, key: String, value: String)
  case storageRemove(local: Bool, key: String)
  case storageClear(local: Bool)
  case indexedDBNames
  case indexedDBSchema(database: String)
  case indexedDBData(database: String, store: String, skip: Int, count: Int)
  case cacheNames
  case cacheEntries(cacheID: String, skip: Int, count: Int)
  case cacheResponse(cacheID: String, requestURL: String)
  case serviceWorkerUpdate(scopeURL: String)
  case serviceWorkerUnregister(scopeURL: String)
  case performanceMetrics
  case domCounters
  case resourceTree
  case resourceContent(url: String)
  case longTasks
  case vitalsInputs
  case parsedScripts(skip: Int, count: Int)
  case scriptSource(id: String)
  case consoleProperties(objectID: String)

  public var id: Int {
    switch self {
    case .storageItems: 1
    case .storageSet: 2
    case .storageRemove: 3
    case .storageClear: 4
    case .indexedDBNames: 5
    case .indexedDBSchema: 6
    case .indexedDBData: 7
    case .cacheNames: 8
    case .cacheEntries: 9
    case .cacheResponse: 10
    case .serviceWorkerUpdate: 11
    case .serviceWorkerUnregister: 12
    case .performanceMetrics: 13
    case .domCounters: 14
    case .resourceTree: 15
    case .resourceContent: 16
    case .longTasks: 17
    case .vitalsInputs: 18
    case .parsedScripts: 19
    case .scriptSource: 20
    case .consoleProperties: 21
    }
  }

  public var parameters: [String: Any]? {
    switch self {
    case .storageItems(let local, let skip, let count):
      guard Self.validPage(skip, count) else { return nil }
      return ["isLocalStorage": local, "skipCount": skip, "pageSize": count]
    case .storageSet(let local, let key, let value):
      guard Self.validStorageText(key), Self.validStorageText(value, maximum: 16_384)
      else { return nil }
      return ["isLocalStorage": local, "key": key, "value": value]
    case .storageRemove(let local, let key):
      guard Self.validStorageText(key) else { return nil }
      return ["isLocalStorage": local, "key": key]
    case .storageClear(let local):
      return ["isLocalStorage": local]
    case .indexedDBNames, .cacheNames, .performanceMetrics, .domCounters,
      .resourceTree, .longTasks, .vitalsInputs:
      return [:]
    case .indexedDBSchema(let database):
      guard Self.validText(database) else { return nil }
      return ["databaseName": database]
    case .indexedDBData(let database, let store, let skip, let count):
      guard Self.validText(database), Self.validText(store), Self.validPage(skip, count)
      else { return nil }
      return [
        "databaseName": database, "objectStoreName": store,
        "skipCount": skip, "pageSize": count,
      ]
    case .cacheEntries(let cacheID, let skip, let count):
      guard Self.validText(cacheID, maximum: 256), Self.validPage(skip, count)
      else { return nil }
      return ["cacheID": cacheID, "skipCount": skip, "pageSize": count]
    case .cacheResponse(let cacheID, let requestURL):
      guard Self.validText(cacheID, maximum: 256), Self.validWebURL(requestURL)
      else { return nil }
      return ["cacheID": cacheID, "requestURL": requestURL]
    case .serviceWorkerUpdate(let scopeURL), .serviceWorkerUnregister(let scopeURL):
      guard Self.validWebURL(scopeURL) else { return nil }
      return ["scopeURL": scopeURL]
    case .resourceContent(let url):
      guard Self.validWebURL(url) else { return nil }
      return ["resourceURL": url]
    case .parsedScripts(let skip, let count):
      guard Self.validPage(skip, count) else { return nil }
      return ["skipCount": skip, "pageSize": count]
    case .scriptSource(let id):
      guard Self.validText(id, maximum: 128) else { return nil }
      return ["scriptID": id]
    case .consoleProperties(let objectID):
      guard Self.validText(objectID, maximum: 4_096) else { return nil }
      return ["objectID": objectID]
    }
  }

  private static func validText(_ value: String, maximum: Int = 4_096) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum
  }

  private static func validStorageText(_ value: String, maximum: Int = 4_096) -> Bool {
    value.utf8.count <= maximum
  }

  private static func validPage(_ skip: Int, _ count: Int) -> Bool {
    (0...10_000).contains(skip) && (1...50).contains(count)
  }

  private static func validWebURL(_ value: String) -> Bool {
    guard validText(value), let parts = URLComponents(string: value) else { return false }
    return ["http", "https"].contains(parts.scheme ?? "")
      && parts.host != nil && parts.user == nil && parts.password == nil
  }
}

/// Named fields projected by the engine. Unknown protocol fields never enter
/// this model; each command has a small fixed field set.
public struct ShaarDevToolsPhase2Item: Equatable, Sendable {
  public let text: [String: String]
  public let number: [String: Double]
  public let flag: [String: Bool]
}

public struct ShaarDevToolsPhase2Reply: Equatable, Sendable {
  public let commandID: Int
  public let items: [ShaarDevToolsPhase2Item]
  public let hasMore: Bool?
  public let body: String?
  public let base64Encoded: Bool?
  public let counters: [String: Int]
  public let truncated: Bool

  public static func decode(_ data: Data, command: ShaarDevToolsPhase2Command) -> Self? {
    let bodyLimit = command.id == 16 || command.id == 20 ? 5 * 1_048_576 : 1_048_576
    let replyLimit = command.id == 16 || command.id == 20 ? 32 * 1_048_576 : 1_050_624
    guard data.count <= replyLimit,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      phase2ReplyInteger(root["schemaVersion"]) == 1,
      phase2ReplyInteger(root["commandID"]) == command.id,
      let rawItems = root["items"] as? [[String: Any]], rawItems.count <= 50,
      let truncated = phase2ReplyBoolean(root["truncated"]),
      Set(root.keys).isSubset(of: [
        "schemaVersion", "commandID", "items", "hasMore",
        "body", "base64Encoded", "documents", "nodes",
        "jsEventListeners", "truncated",
      ])
    else { return nil }
    var items: [ShaarDevToolsPhase2Item] = []
    for raw in rawItems {
      guard let item = decodeItem(raw, commandID: command.id) else { return nil }
      items.append(item)
    }
    let body = root["body"] as? String
    if root["body"] != nil && (body == nil || body!.utf8.count > bodyLimit) { return nil }
    let encoded = root["base64Encoded"].flatMap(phase2ReplyBoolean)
    if root["base64Encoded"] != nil && encoded == nil { return nil }
    if (body == nil) != (encoded == nil) { return nil }
    if body != nil && command.id != 10 && command.id != 16 && command.id != 20 { return nil }
    let hasMore = root["hasMore"].flatMap(phase2ReplyBoolean)
    if root["hasMore"] != nil && hasMore == nil { return nil }
    var counters: [String: Int] = [:]
    for key in ["documents", "nodes", "jsEventListeners"] {
      if let value = root[key] {
        guard command.id == 14,
          let count = phase2ReplyInteger(value), count >= 0
        else { return nil }
        counters[key] = count
      }
    }
    return Self(
      commandID: command.id, items: items, hasMore: hasMore,
      body: body, base64Encoded: encoded, counters: counters,
      truncated: truncated)
  }

  private static func decodeItem(
    _ raw: [String: Any], commandID: Int
  ) -> ShaarDevToolsPhase2Item? {
    let allowed: Set<String>
    switch commandID {
    case 1: allowed = ["key", "value"]
    case 5, 6: allowed = ["name"]
    case 7: allowed = ["key", "primaryKey", "value"]
    case 8: allowed = ["cacheID", "name"]
    case 9: allowed = ["url", "method", "status"]
    case 13: allowed = ["name", "value"]
    case 15: allowed = ["url", "type", "mimeType"]
    case 19: allowed = ["url", "scriptID", "sourceMapURL"]
    case 17: allowed = ["name", "startTime", "duration"]
    case 18: allowed = ["name", "value", "startTime", "duration", "interactionID"]
    case 21: allowed = ["name", "value", "objectID"]
    default: allowed = []
    }
    guard Set(raw.keys).isSubset(of: allowed) else { return nil }
    var text: [String: String] = [:]
    var number: [String: Double] = [:]
    for (key, value) in raw {
      if let string = value as? String, string.utf8.count <= 4_096 {
        text[key] = string
      } else if let numberValue = value as? NSNumber,
        CFGetTypeID(numberValue) == CFBooleanGetTypeID()
      {
        return nil
      } else if let count = value as? Double, count.isFinite,
        ["status", "value", "startTime", "duration", "interactionID"].contains(key)
      {
        number[key] = count
      } else {
        return nil
      }
    }
    return ShaarDevToolsPhase2Item(text: text, number: number, flag: [:])
  }
}

public enum ShaarDevToolsPhase2EventID: Int, Sendable {
  case storageAdded = 12
  case storageUpdated = 13
  case storageRemoved = 14
  case storageCleared = 15
  case workerRegistration = 16
  case workerVersion = 17
  case workerError = 18
  case timeline = 19
  case scriptParsed = 30
}

public struct ShaarDevToolsPhase2Event: Equatable, Sendable {
  public let sequence: UInt64
  public let leaseID: UInt32
  public let id: ShaarDevToolsPhase2EventID
  public let localStorage: Bool?
  public let text: [String: String]
  public let number: [String: Double]
  public let flag: [String: Bool]
  public let items: [ShaarDevToolsPhase2Item]
  public let truncated: Bool
}

public enum ShaarDevToolsPhase2EventRouter {
  public static func decode(
    _ event: ShaarCopiedEvent, scope: ShaarNavigationScope,
    windowID: String, tabID: String, leaseID: UInt32,
    afterSequence: UInt64 = 0
  ) -> ShaarDevToolsPhase2Event? {
    guard event.kind == 14, event.sequence > afterSequence,
      event.profileID == Data(scope.profileID.utf8),
      event.sessionID == Data((scope.sessionID ?? "").utf8),
      event.windowID == Data(windowID.utf8), event.tabID == Data(tabID.utf8),
      event.payloadJSON.count <= 32_768,
      let root = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      Set(root.keys) == ["schemaVersion", "kind", "eventID", "leaseID", "data"],
      phase2ReplyInteger(root["schemaVersion"]) == 1,
      root["kind"] as? String == "panelEvent",
      let rawID = phase2ReplyInteger(root["eventID"]),
      let id = ShaarDevToolsPhase2EventID(rawValue: rawID),
      phase2ReplyInteger(root["leaseID"]) == Int(leaseID),
      let data = root["data"] as? [String: Any],
      let truncated = phase2ReplyBoolean(data["truncated"])
    else { return nil }
    let allowed = allowedFields(id)
    guard Set(data.keys).isSubset(of: allowed) else { return nil }
    var text: [String: String] = [:]
    var number: [String: Double] = [:]
    var flag: [String: Bool] = [:]
    var items: [ShaarDevToolsPhase2Item] = []
    for (key, value) in data where key != "truncated" && key != "items" {
      if let string = value as? String, string.utf8.count <= 4_096 {
        text[key] = string
      } else if let numberValue = value as? NSNumber,
        CFGetTypeID(numberValue) == CFBooleanGetTypeID()
      {
        flag[key] = numberValue.boolValue
      } else if let double = value as? Double, double.isFinite {
        number[key] = double
      } else {
        return nil
      }
    }
    if let rawItems = data["items"] {
      guard let rows = rawItems as? [[String: Any]], rows.count <= 32 else { return nil }
      for row in rows {
        guard let item = decodeEventItem(row, id: id) else { return nil }
        items.append(item)
      }
    }
    guard
      requiredFieldsPresent(
        id, text: text, number: number,
        flag: flag, hasItems: data["items"] != nil)
    else { return nil }
    return ShaarDevToolsPhase2Event(
      sequence: event.sequence, leaseID: leaseID, id: id,
      localStorage: flag["isLocalStorage"], text: text, number: number,
      flag: flag, items: items, truncated: truncated)
  }

  private static func requiredFieldsPresent(
    _ id: ShaarDevToolsPhase2EventID,
    text: [String: String], number: [String: Double],
    flag: [String: Bool], hasItems: Bool
  ) -> Bool {
    switch id {
    case .storageAdded, .storageUpdated:
      return flag["isLocalStorage"] != nil && text["key"] != nil && text["value"] != nil
    case .storageRemoved:
      return flag["isLocalStorage"] != nil && text["key"] != nil
    case .storageCleared:
      return flag["isLocalStorage"] != nil
    case .workerRegistration, .workerVersion:
      return hasItems
    case .workerError:
      return text["text"] != nil
    case .timeline:
      guard let type = text["type"], number["time"] != nil else { return false }
      if type == "largest-contentful-paint" { return number["size"] != nil }
      if type == "layout-shift" {
        return number["value"] != nil && flag["hadRecentInput"] != nil
      }
      return false
    case .scriptParsed:
      return text["url"] != nil && text["scriptID"] != nil
    }
  }

  private static func allowedFields(_ id: ShaarDevToolsPhase2EventID) -> Set<String> {
    switch id {
    case .storageAdded, .storageUpdated: ["isLocalStorage", "key", "value", "truncated"]
    case .storageRemoved: ["isLocalStorage", "key", "truncated"]
    case .storageCleared: ["isLocalStorage", "truncated"]
    case .workerRegistration, .workerVersion: ["items", "truncated"]
    case .workerError: ["text", "truncated"]
    case .timeline:
      [
        "type", "name", "time", "duration", "renderTime", "loadTime",
        "size", "value", "hadRecentInput", "truncated",
      ]
    case .scriptParsed: ["url", "scriptID", "sourceMapURL", "truncated"]
    }
  }

  private static func decodeEventItem(
    _ row: [String: Any], id: ShaarDevToolsPhase2EventID
  ) -> ShaarDevToolsPhase2Item? {
    let allowed: Set<String>
    switch id {
    case .workerRegistration: allowed = ["scopeURL", "registrationID", "deleted"]
    case .workerVersion:
      allowed = ["scriptURL", "registrationID", "versionID", "status", "runningStatus"]
    default: return nil
    }
    guard Set(row.keys).isSubset(of: allowed) else { return nil }
    var text: [String: String] = [:]
    var flag: [String: Bool] = [:]
    for (key, value) in row {
      if let string = value as? String, string.utf8.count <= 4_096 {
        text[key] = string
      } else if let numberValue = value as? NSNumber,
        CFGetTypeID(numberValue) == CFBooleanGetTypeID(), key == "deleted"
      {
        flag[key] = numberValue.boolValue
      } else {
        return nil
      }
    }
    return ShaarDevToolsPhase2Item(text: text, number: [:], flag: flag)
  }
}
