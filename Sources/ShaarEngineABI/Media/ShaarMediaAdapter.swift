// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ShaarMediaOperation: UInt32, Sendable {
  case getState = 1100
  case control = 1101
  case setAutoPictureInPicture = 1102
  case enterPictureInPicture = 1103
  case exitPictureInPicture = 1104
  case listCaptureSources = 1105
  case captureReply = 1106
}

public enum ShaarMediaCommand: Int, Codable, Sendable {
  case play = 0
  case pause = 1
  case previousTrack = 2
  case nextTrack = 3
  case seekBackward = 4
  case seekForward = 5
  case seekTo = 6
  case setTabMuted = 7
  case setElementVolume = 8
  case pipPlay = 9
  case pipPause = 10
  case pipSkip = 11
  case pipEnter = 12
  case pipExit = 13
}

public struct ShaarMediaScope: Equatable, Sendable {
  public let profileID: String
  public let sessionID: String?
  public let tabID: String

  public init(profileID: String, sessionID: String? = nil, tabID: String) {
    self.profileID = profileID
    self.sessionID = sessionID
    self.tabID = tabID
  }
}

public struct ShaarMediaState: Decodable, Equatable, Sendable {
  public enum PlaybackState: String, Decodable, Sendable {
    case none, paused, playing
  }

  public let schemaVersion: Int
  public let playbackState: PlaybackState
  public let title: String
  public let artist: String
  public let album: String
  public let artwork: String?
  public let supportedActions: [UInt32]
  public let canSeek: Bool
  public let hasVideo: Bool
  public let tabMuted: Bool
  public let pageVolume: Double?
  public let silent: Bool?
  public let pipVideoState: String?
  public let videoWidth: UInt32?
  public let videoHeight: UInt32?

  enum CodingKeys: String, CodingKey {
    case schemaVersion, playbackState, title, artist, album, artwork, supportedActions
    case canSeek, hasVideo, tabMuted, pageVolume, silent, pipVideoState, videoWidth, videoHeight
  }
}

public struct ShaarMediaCaptureSource: Decodable, Equatable, Sendable {
  public let label: String
  public let token: String
}

public enum ShaarMediaChange: Equatable, Sendable {
  case stateChanged(ShaarMediaState)
  case pictureInPictureChanged(String?)
  case captureChanged(String)
}

public protocol ShaarMediaTransport: Sendable {
  func submit(
    scope: ShaarMediaScope, operation: ShaarMediaOperation, arguments: Data
  ) async throws -> Data
}

public enum ShaarMediaAdapterError: Error, Equatable, Sendable {
  case malformedResponse
  case invalidControl
}

/// The engine lane stays opt-in until the source-engine implementation is selected.
public struct ShaarMediaAdapter: Sendable {
  private let transport: any ShaarMediaTransport
  public let implementation: ShaarEngineImplementation

  public init(
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarMediaTransport
  ) {
    self.implementation = implementation
    self.transport = transport
  }

  public static func selected(
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarMediaTransport
  ) -> Self? {
    guard implementation == .shaar else { return nil }
    return Self(implementation: implementation, transport: transport)
  }

  public func state(scope: ShaarMediaScope) async throws -> ShaarMediaState {
    let data = try await send(scope, .getState, ["schemaVersion": 1])
    let state = try JSONDecoder().decode(ShaarMediaState.self, from: data)
    guard state.schemaVersion == 1,
      state.supportedActions.allSatisfy({ $0 <= UInt32(ShaarMediaCommand.pipExit.rawValue) }),
      state.pageVolume == nil
        || (state.pageVolume!.isFinite && (0...1).contains(state.pageVolume!)),
      (state.videoWidth == nil) == (state.videoHeight == nil)
    else { throw ShaarMediaAdapterError.malformedResponse }
    return state
  }

  public func control(
    _ command: ShaarMediaCommand, scope: ShaarMediaScope, value: Double? = nil
  ) async throws {
    guard Self.valid(command, value: value) else { throw ShaarMediaAdapterError.invalidControl }
    var args: [String: Any] = ["schemaVersion": 1, "command": command.rawValue]
    if let value {
      args["value"] = command == .setTabMuted ? (value == 1) : value
    }
    try Self.requireEmptySuccess(try await send(scope, .control, args))
  }

  public func setTabMuted(_ muted: Bool, scope: ShaarMediaScope) async throws {
    try await control(.setTabMuted, scope: scope, value: muted ? 1 : 0)
  }

  public func setAutoPictureInPicture(_ allowed: Bool, scope: ShaarMediaScope) async throws {
    try Self.requireEmptySuccess(
      try await send(
        scope, .setAutoPictureInPicture,
        ["schemaVersion": 1, "allowed": allowed]))
  }

  public func enterPictureInPicture(scope: ShaarMediaScope) async throws {
    try Self.requireEmptySuccess(
      try await send(scope, .enterPictureInPicture, ["schemaVersion": 1]))
  }

  public func exitPictureInPicture(scope: ShaarMediaScope) async throws {
    try Self.requireEmptySuccess(try await send(scope, .exitPictureInPicture, ["schemaVersion": 1]))
  }

  public func captureSources(scope: ShaarMediaScope) async throws -> [ShaarMediaCaptureSource] {
    let data = try await send(scope, .listCaptureSources, ["schemaVersion": 1])
    let reply = try JSONDecoder().decode(CaptureSourcesReply.self, from: data)
    guard reply.schemaVersion == 1,
      reply.sources.allSatisfy({ !$0.label.isEmpty && !$0.token.isEmpty }),
      Set(reply.sources.map(\.token)).count == reply.sources.count
    else { throw ShaarMediaAdapterError.malformedResponse }
    return reply.sources
  }

  public func replyToCapture(
    scope: ShaarMediaScope, promptID: String, token: String?
  ) async throws {
    guard !promptID.isEmpty, token.map({ !$0.isEmpty }) ?? true else {
      throw ShaarMediaAdapterError.invalidControl
    }
    var args: [String: Any] = ["schemaVersion": 1, "promptID": promptID]
    args["decision"] = token == nil ? "cancel" : "approve"
    if let token { args["sourceToken"] = token }
    try Self.requireEmptySuccess(try await send(scope, .captureReply, args))
  }

  public func decodeEvent(
    _ event: ShaarCopiedEvent, scope: ShaarMediaScope
  ) throws -> ShaarMediaChange? {
    guard event.kind == 15,
      String(data: event.profileID, encoding: .utf8) == scope.profileID,
      String(data: event.sessionID, encoding: .utf8) == (scope.sessionID ?? ""),
      String(data: event.tabID, encoding: .utf8) == scope.tabID
    else { return nil }
    guard let root = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      root["schemaVersion"] as? Int == 1,
      let kind = root["kind"] as? String
    else { throw ShaarMediaAdapterError.malformedResponse }
    switch kind {
    case "state_changed":
      guard let stateData = try? JSONSerialization.data(withJSONObject: root["state"] ?? [:]),
        let state = try? JSONDecoder().decode(ShaarMediaState.self, from: stateData),
        state.schemaVersion == 1
      else { throw ShaarMediaAdapterError.malformedResponse }
      return .stateChanged(state)
    case "pip_changed":
      return .pictureInPictureChanged(root["state"] as? String)
    case "capture_state_changed":
      guard let capture = root["capture"] as? String else {
        throw ShaarMediaAdapterError.malformedResponse
      }
      return .captureChanged(capture)
    default:
      throw ShaarMediaAdapterError.malformedResponse
    }
  }

  private func send(
    _ scope: ShaarMediaScope, _ operation: ShaarMediaOperation, _ args: [String: Any]
  ) async throws -> Data {
    guard !scope.profileID.isEmpty, !scope.tabID.isEmpty,
      !(scope.sessionID?.isEmpty ?? false),
      let json = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
    else { throw ShaarMediaAdapterError.invalidControl }
    return try await transport.submit(scope: scope, operation: operation, arguments: json)
  }

  private static func valid(_ command: ShaarMediaCommand, value: Double?) -> Bool {
    switch command {
    case .setTabMuted:
      return value.map { $0 == 0 || $0 == 1 } ?? false
    case .setElementVolume:
      return value.map { $0.isFinite && (0...1).contains($0) } ?? false
    case .seekTo:
      return value.map { $0.isFinite && (0...86_400).contains($0) } ?? false
    case .pipSkip:
      return value.map {
        $0.isFinite && $0 != 0 && (-86_400...86_400).contains($0)
      } ?? false
    default:
      return value == nil
    }
  }

  private static func requireEmptySuccess(_ data: Data) throws {
    guard data.isEmpty || data == Data("{}".utf8) || data == Data(#"{"schemaVersion":1}"#.utf8)
    else { throw ShaarMediaAdapterError.malformedResponse }
  }

  private struct CaptureSourcesReply: Decodable {
    let schemaVersion: Int
    let sources: [ShaarMediaCaptureSource]
  }
}
