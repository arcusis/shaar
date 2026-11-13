// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

private func downloadsInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

public struct ShaarDownloadRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let url: String
  public let filename: String
  public let path: String
  public let state: State
  public let paused: Bool
  public let received: Int64
  public let total: Int64
  public let speed: Int64
  public let mimeType: String
  public let dangerous: Bool
  public let offTheRecord: Bool
  public let error: String?
  public let startTime: Int64

  public enum State: String, Codable, Sendable {
    case downloading, finished, cancelled, failed
  }

  enum CodingKeys: String, CodingKey {
    case id, url, filename, path, state, paused, received, total, speed, mimeType, dangerous,
      offTheRecord, error, startTime
  }

  public init(
    id: String, url: String, filename: String, path: String, state: State, paused: Bool,
    received: Int64, total: Int64, speed: Int64, mimeType: String, dangerous: Bool,
    offTheRecord: Bool, error: String?, startTime: Int64
  ) {
    self.id = id
    self.url = url
    self.filename = filename
    self.path = path
    self.state = state
    self.paused = paused
    self.received = received
    self.total = total
    self.speed = speed
    self.mimeType = mimeType
    self.dangerous = dangerous
    self.offTheRecord = offTheRecord
    self.error = error
    self.startTime = startTime
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    guard !id.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .id, in: values, debugDescription: "Expected a non-empty download ID")
    }
    url = try values.decode(String.self, forKey: .url)
    filename = try values.decode(String.self, forKey: .filename)
    path = try values.decode(String.self, forKey: .path)
    state = try values.decode(State.self, forKey: .state)
    paused = try values.decode(Bool.self, forKey: .paused)
    let decodedReceived = try values.decodeInteger(forKey: .received)
    guard decodedReceived >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .received, in: values, debugDescription: "Expected nonnegative bytes received")
    }
    received = decodedReceived
    let decodedTotal = try values.decodeInteger(forKey: .total)
    guard decodedTotal == -1 || decodedTotal >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .total, in: values, debugDescription: "Expected nonnegative total or unknown size")
    }
    total = decodedTotal
    let decodedSpeed = try values.decodeInteger(forKey: .speed)
    guard decodedSpeed >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .speed, in: values, debugDescription: "Expected nonnegative download speed")
    }
    speed = decodedSpeed
    mimeType = try values.decode(String.self, forKey: .mimeType)
    dangerous = try values.decode(Bool.self, forKey: .dangerous)
    offTheRecord = try values.decode(Bool.self, forKey: .offTheRecord)
    error = try values.decodeIfPresent(String.self, forKey: .error)
    let decodedStartTime = try values.decodeInteger(forKey: .startTime)
    guard decodedStartTime >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .startTime, in: values, debugDescription: "Expected nonnegative start time")
    }
    startTime = decodedStartTime
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeInteger(forKey key: Key) throws -> Int64 {
    if let integer = try? decode(Int64.self, forKey: key) { return integer }
    let number = try decode(Double.self, forKey: key)
    guard number.isFinite, number.rounded(.towardZero) == number,
      number >= Double(Int64.min), number < Double(Int64.max)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: self, debugDescription: "Expected an integer")
    }
    return Int64(number)
  }
}

public enum ShaarDownloadAction: String, Codable, Sendable {
  case pause, resume, cancel, remove
}

public enum ShaarDownloadsError: Error, Equatable, Sendable {
  case invalidControl
  case malformedResponse
  case invalidControl
  case unsafeTarget
  case engine(ShaarStatusCode, message: String)
}

public enum ShaarDownloadChange: Equatable, Sendable {
  case upsert(ShaarDownloadRecord)
  case remove(String)
}

/// A narrow transport boundary lets the adapter use the ABI loader in shipping
/// code and a deterministic fake in unit tests. Scope ownership is supplied by
/// the ABI session manager and is checked again by shaar_submit.
public protocol ShaarDownloadsTransport: Sendable {
  func submit(operation: UInt32, arguments: Data) async throws -> Data
}

public struct ShaarDownloadsAdapter: Sendable {
  public static let listOperation: UInt32 = 400
  public static let controlOperation: UInt32 = 401
  public static let directoryOperation: UInt32 = 402

  private let transport: any ShaarDownloadsTransport
  public let implementation: ShaarEngineImplementation

  public init(
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarDownloadsTransport
  ) {
    self.implementation = implementation
    self.transport = transport
  }

  /// Constructs the Shaar downloads adapter.
  public static func selected(
    implementation: ShaarEngineImplementation,
    transport: any ShaarDownloadsTransport
  ) -> Self? {
    guard implementation == .shaar else { return nil }
    return Self(implementation: implementation, transport: transport)
  }

  /// Decodes only download events owned by the exact profile/session view.
  /// A private event can therefore never enter the regular profile cache.
  public func decodeEvent(
    _ event: ShaarCopiedEvent,
    profileID: String,
    sessionID: String?
  ) throws -> ShaarDownloadChange? {
    guard event.kind == 9,
      String(data: event.profileID, encoding: .utf8) == profileID,
      String(data: event.sessionID, encoding: .utf8) == (sessionID ?? "")
    else { return nil }
    guard
      let payload = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      downloadsInteger(payload["schemaVersion"]) == 1
    else { throw ShaarDownloadsError.malformedResponse }
    switch payload["change"] as? String {
    case "upsert":
      guard let value = payload["download"],
        let data = try? JSONSerialization.data(withJSONObject: value),
        let row = try? JSONDecoder().decode(ShaarDownloadRecord.self, from: data)
      else { throw ShaarDownloadsError.malformedResponse }
      return .upsert(row)
    case "remove":
      guard let id = payload["downloadId"] as? String, !id.isEmpty else {
        throw ShaarDownloadsError.malformedResponse
      }
      return .remove(id)
    default:
      throw ShaarDownloadsError.malformedResponse
    }
  }

  public func list() async throws -> [ShaarDownloadRecord] {
    let data = try await transport.submit(
      operation: Self.listOperation, arguments: Self.json(["schemaVersion": 1]))
    let envelope = try JSONDecoder().decode(ListReply.self, from: data)
    guard envelope.schemaVersion == 1,
      Set(envelope.downloads.map(\.id)).count == envelope.downloads.count
    else { throw ShaarDownloadsError.malformedResponse }
    return envelope.downloads
  }

  public func control(_ action: ShaarDownloadAction, id: String) async throws {
    guard !id.isEmpty else { throw ShaarDownloadsError.invalidControl }
    let args = try Self.json(["schemaVersion": 1, "downloadId": id, "action": action.rawValue])
    let response = try await transport.submit(operation: Self.controlOperation, arguments: args)
    guard response.isEmpty || response == Data("{}".utf8) else {
      throw ShaarDownloadsError.malformedResponse
    }
  }

  public func directory() async throws -> String {
    let data = try await transport.submit(
      operation: Self.directoryOperation,
      arguments: Self.json(["schemaVersion": 1, "action": "get"]))
    let reply = try JSONDecoder().decode(DirectoryReply.self, from: data)
    guard reply.schemaVersion == 1, reply.directory.hasPrefix("/") else {
      throw ShaarDownloadsError.malformedResponse
    }
    return reply.directory
  }

  public func setDirectory(_ path: String) async throws -> String {
    let data = try await transport.submit(
      operation: Self.directoryOperation,
      arguments: Self.json(["schemaVersion": 1, "action": "set", "directory": path]))
    return try Self.decodeDirectory(data)
  }

  public func useDefaultDirectory() async throws -> String {
    let data = try await transport.submit(
      operation: Self.directoryOperation,
      arguments: Self.json(["schemaVersion": 1, "action": "useDefault"]))
    return try Self.decodeDirectory(data)
  }

  /// Allows a completed file to be opened only beneath Chromium's acknowledged
  /// effective directory. Symlinks are resolved on both sides before compare.
  public func validatedTarget(for record: ShaarDownloadRecord, effectiveDirectory: URL) throws
    -> URL
  {
    guard !record.path.isEmpty, record.path.hasPrefix("/") else {
      throw ShaarDownloadsError.unsafeTarget
    }
    let target = URL(fileURLWithPath: record.path).standardizedFileURL.resolvingSymlinksInPath()
    let root = effectiveDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = root.path == "/" ? "/" : root.path + "/"
    guard target.isFileURL, target.path.hasPrefix(rootPath), target.path != root.path else {
      throw ShaarDownloadsError.unsafeTarget
    }
    return target
  }

  private static func decodeDirectory(_ data: Data) throws -> String {
    let reply = try JSONDecoder().decode(DirectoryReply.self, from: data)
    guard reply.schemaVersion == 1, reply.directory.hasPrefix("/") else {
      throw ShaarDownloadsError.malformedResponse
    }
    return reply.directory
  }

  private static func json(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private struct ListReply: Decodable {
    let schemaVersion: Int
    let downloads: [ShaarDownloadRecord]
  }

  private struct DirectoryReply: Decodable {
    let schemaVersion: Int
    let directory: String
  }
}
