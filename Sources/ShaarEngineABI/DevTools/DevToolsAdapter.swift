// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation
import ShaarEngineABIC

private func devToolsJSONBoolean(_ value: Any?) -> Bool? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) == CFBooleanGetTypeID()
  else { return nil }
  return number.boolValue
}

private func devToolsEnvelopeInteger(_ value: Any?) -> Int? {
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  return Int(exactly: number.doubleValue)
}

public enum ShaarDevToolsOperation: UInt32, Sendable {
  case call = 1000
  case show = 1001
  case close = 1002
  case state = 1003
  case setDock = 1004
  case controlEnable = 1005
  case controlDisable = 1006
  case controlStatus = 1007
  case panelOpen = 1009
  case panelClose = 1010
  case panelGetResponseBody = 1011
  case panelPhase2Command = 1012
  case viewportOpen = 1013
  case viewportClose = 1014
  case viewportAdd = 1015
  case viewportRemove = 1016
  case viewportAction = 1017
  case viewportFrame = 1018
  case panelScreencast = 1019
  case panelNetworkRules = 1080
}

public enum ShaarDevToolsScreencastCommand: Sendable {
  case start
  case stop
  case ack(sessionID: Int)

  var fields: [String: Any]? {
    switch self {
    case .start: return ["commandID": 1]
    case .stop: return ["commandID": 2]
    case .ack(let sessionID):
      guard sessionID > 0 else { return nil }
      return ["commandID": 3, "sessionID": sessionID]
    }
  }
}

public enum ShaarDevToolsCapability: UInt32, Sendable {
  case inspector = 1
  case developer = 2
  case devToolsPanel = 3
}

public enum ShaarDevToolsCommand: UInt32, CaseIterable, Sendable {
  case runtimeEvaluate = 1
  case runtimeReleaseObject = 2
  case runtimeGetProperties = 3
  case runtimeReleaseObjectGroup = 4
  case domEnable = 5
  case domGetDocument = 6
  case domRequestNode = 7
  case domGetBoxModel = 8
  case cssEnable = 9
  case cssGetPlatformFontsForNode = 10
  case cssGetBackgroundColors = 11
  case cssGetMatchedStylesForNode = 12
  case cssGetComputedStyleForNode = 13
  case cssGetStylesheetText = 14
  case pageEnable = 15
  case pageGetResourceTree = 16
  case pageGetResourceContent = 17
  case pageCaptureScreenshot = 18
  case overlayEnable = 19
  case overlayDisable = 20
  case overlaySetShowGridOverlays = 21
  case overlaySetShowFlexOverlays = 22
  case overlayGetGridHighlightObjectsForTest = 23
  case domDescribeNode = 24
  case accessibilityGetPartialAXTree = 25
  case emulationSetDeviceMetricsOverride = 26
  case emulationClearDeviceMetricsOverride = 27
  case networkEnable = 28
  case networkEmulateNetworkConditions = 29
  case emulationSetCPUThrottlingRate = 30
  case emulationSetGeolocationOverride = 31
  case emulationClearGeolocationOverride = 32
  case emulationSetTimezoneOverride = 33
  case emulationSetLocaleOverride = 34
  case emulationSetUserAgentOverride = 35
  case emulationSetEmulatedMedia = 36
  case performanceEnable = 37
  case performanceGetMetrics = 38
  case pageAddScriptToEvaluateOnNewDocument = 39
  case pageRemoveScriptToEvaluateOnNewDocument = 40
  case networkGetCookies = 41
  case networkSetCookie = 42
  case networkDeleteCookies = 43
  case emulationSetSafeAreaInsetsOverride = 44
  case domRequestChildNodes = 45
  case domSetAttributeValue = 46
  case domRemoveAttribute = 47
  case domSetNodeValue = 48
  case domRemoveNode = 49
  case domSetOuterHTML = 50
  case domMoveTo = 51
  case domMarkUndoableState = 52
  case domUndo = 53
  case domPerformSearch = 54
  case domGetSearchResults = 55
  case domDiscardSearchResults = 56
  case overlayHighlightNode = 57
  case overlayHideHighlight = 58
  case domResolveNode = 59
  case runtimeCallFunctionOn = 60
  case domGetOuterHTML = 61
  case networkSetCacheDisabled = 69
  // 62-76 stay on the ObjC bridge. 77-79 are the heap profiler.
  case heapProfilerTakeHeapSnapshot = 77
  case heapProfilerStartTrackingHeapObjects = 78
  case heapProfilerStopTrackingHeapObjects = 79

  fileprivate func permits(_ capability: ShaarDevToolsCapability) -> Bool {
    switch capability {
    case .inspector:
      return rawValue <= 25 || (45...61).contains(rawValue)
    case .developer:
      return rawValue <= 4 || (15...18).contains(rawValue) || (26...40).contains(rawValue)
        || self == .emulationSetSafeAreaInsetsOverride
        || self == .networkSetCacheDisabled
        || (77...79).contains(rawValue)
    case .devToolsPanel:
      return false
    }
  }
}

public struct ShaarDevToolsRequest: Equatable, Sendable {
  public let operation: ShaarDevToolsOperation
  public let scope: ShaarNavigationScope
  public let windowID: String
  public let tabID: String
  public let payload: Data
}

public protocol ShaarDevToolsSubmitting: Sendable {
  func submit(
    _ request: ShaarDevToolsRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64
}

private final class ShaarDevToolsReplyBox: @unchecked Sendable {
  let expectedRequestID: UInt64
  let completion: @Sendable (Result<Data, ShaarEngineError>) -> Void
  init(
    _ requestID: UInt64, _ completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) {
    expectedRequestID = requestID
    self.completion = completion
  }
}

private final class ShaarDevToolsRequestIDs: @unchecked Sendable {
  private let lock = NSLock()
  private var next: UInt64 = 1
  func take() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let value = next
    next &+= 1
    if next == 0 { next = 1 }
    return value
  }
}

private func copyDevToolsBytes(_ bytes: shaar_bytes) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid DevTools byte slice")
  }
  guard bytes.size > 0, let pointer = bytes.data else { return Data() }
  return Data(bytes: pointer, count: bytes.size)
}

private let shaarDevToolsABICallback: shaar_reply_fn = { context, result in
  guard let context else { return }
  let box = Unmanaged<ShaarDevToolsReplyBox>.fromOpaque(context).takeRetainedValue()
  guard let result else {
    box.completion(.failure(.invalidEvent("missing DevTools result")))
    return
  }
  do {
    let value = result.pointee
    guard value.size >= UInt32(MemoryLayout<shaar_result>.size),
      value.request_id == box.expectedRequestID
    else { throw ShaarEngineError.invalidEvent("invalid DevTools result envelope") }
    guard value.error.size >= UInt32(MemoryLayout<shaar_error>.size) else {
      throw ShaarEngineError.invalidEvent("short DevTools error")
    }
    try ShaarStatusCode.decode(
      UInt32(value.error.code.rawValue), platformCode: value.error.platform_code,
      message: String(decoding: try copyDevToolsBytes(value.error.message), as: UTF8.self))
    let data = try copyDevToolsBytes(value.payload_json)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      devToolsEnvelopeInteger(root["schemaVersion"]) == 1
    else { throw ShaarEngineError.invalidEvent("invalid DevTools response payload") }
    box.completion(.success(data))
  } catch let error as ShaarEngineError {
    box.completion(.failure(error))
  } catch {
    box.completion(.failure(.invalidEvent("invalid DevTools response bytes")))
  }
}

/// Concrete transport. Scope and target resolution are delegated to the same
/// engine-owned handle resolver used by navigation; this adapter never guesses.
public struct ShaarDevToolsABITransport: ShaarDevToolsSubmitting, @unchecked Sendable {
  private let submitSymbol: UnsafeRawPointer
  private let handleResolver: any ShaarNavigationHandleResolving
  private let requestIDs: ShaarDevToolsRequestIDs

  public init(resolver: ShaarSymbolResolving, handleResolver: any ShaarNavigationHandleResolving)
    throws
  {
    guard let symbol = resolver.symbol(named: "shaar_submit") else {
      throw ShaarEngineError.missingSymbol("shaar_submit")
    }
    submitSymbol = symbol
    self.handleResolver = handleResolver
    requestIDs = ShaarDevToolsRequestIDs()
  }

  public func submit(
    _ request: ShaarDevToolsRequest,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    let handles = try handleResolver.resolve(
      scope: request.scope, windowID: request.windowID, tabID: request.tabID)
    guard handles.scope.size >= UInt32(MemoryLayout<shaar_scope>.size),
      (handles.scope.profile != nil) != (handles.scope.private_session != nil)
    else { throw ShaarEngineError.invalidEvent("native DevTools scope is invalid") }
    let requestID = requestIDs.take()
    let box = ShaarDevToolsReplyBox(requestID, completion)
    let context = Unmanaged.passRetained(box).toOpaque()
    var immediateError = shaar_error(
      size: UInt32(MemoryLayout<shaar_error>.size), code: shaar_error_code(rawValue: 0),
      platform_code: 0,
      message: shaar_bytes(data: nil, size: 0))
    let status = request.payload.withUnsafeBytes { raw -> UInt32 in
      let bytes = raw.bindMemory(to: CChar.self)
      var scope = handles.scope
      return shaar_navigation_submit_invoke(
        submitSymbol, handles.engine, &scope, handles.window, handles.tab,
        request.operation.rawValue,
        shaar_bytes(data: bytes.baseAddress, size: bytes.count), requestID,
        shaarDevToolsABICallback, context, &immediateError)
    }
    guard status == 0 else {
      Unmanaged<ShaarDevToolsReplyBox>.fromOpaque(context).release()
      guard immediateError.size >= UInt32(MemoryLayout<shaar_error>.size) else {
        throw ShaarEngineError.invalidEvent("short DevTools error")
      }
      try ShaarStatusCode.decode(
        status, platformCode: immediateError.platform_code,
        message: String(decoding: try copyDevToolsBytes(immediateError.message), as: UTF8.self))
      throw ShaarEngineError.invalidStatusCode(status)
    }
    return requestID
  }
}

public struct ShaarDevToolsAdapter: Sendable {
  private let engine: any ShaarDevToolsSubmitting
  public let implementation: ShaarEngineImplementation

  public init?(
    implementation: ShaarEngineImplementation = .shippingDefault,
    engine: any ShaarDevToolsSubmitting
  ) {
    guard implementation == .shaar else { return nil }
    self.implementation = implementation
    self.engine = engine
  }

  public func call(
    capability: ShaarDevToolsCapability, command: ShaarDevToolsCommand,
    parametersJSON: Data = Data("{}".utf8), scope: ShaarNavigationScope,
    windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard command.permits(capability), !scope.profileID.isEmpty,
      scope.sessionID.map({ !$0.isEmpty }) ?? true,
      !windowID.isEmpty, !tabID.isEmpty,
      let params = try JSONSerialization.jsonObject(with: parametersJSON) as? [String: Any]
    else { throw ShaarEngineError.invalidEvent("invalid or disallowed DevTools command") }
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "schemaVersion": 1, "capability": capability.rawValue,
        "command": command.rawValue, "params": params,
      ],
      options: [.sortedKeys])
    return try engine.submit(
      ShaarDevToolsRequest(
        operation: .call, scope: scope, windowID: windowID,
        tabID: tabID, payload: payload), completion: completion)
  }

  public func setFrontend(
    open: Bool, scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard !scope.profileID.isEmpty, !windowID.isEmpty, !tabID.isEmpty else {
      throw ShaarEngineError.invalidEvent("invalid DevTools target")
    }
    return try engine.submit(
      ShaarDevToolsRequest(
        operation: open ? .show : .close, scope: scope,
        windowID: windowID, tabID: tabID,
        payload: Data("{\"schemaVersion\":1}".utf8)),
      completion: completion)
  }

  public func frontendState(
    scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard !scope.profileID.isEmpty, scope.sessionID.map({ !$0.isEmpty }) ?? true,
      !windowID.isEmpty, !tabID.isEmpty
    else { throw ShaarEngineError.invalidEvent("invalid DevTools target") }
    return try engine.submit(
      ShaarDevToolsRequest(
        operation: .state, scope: scope, windowID: windowID, tabID: tabID,
        payload: Data("{\"schemaVersion\":1}".utf8)), completion: completion)
  }

  public func openPanel(
    scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<UInt32, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    return try submitPanel(.panelOpen, fields: [:], scope: scope, windowID: windowID, tabID: tabID)
    {
      result in
      completion(
        result.flatMap { payload in
          guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys) == ["schemaVersion", "leaseID"],
            devToolsEnvelopeInteger(object["schemaVersion"]) == 1,
            let leaseID = devToolsEnvelopeInteger(object["leaseID"]),
            leaseID > 0, let value = UInt32(exactly: leaseID)
          else { return .failure(.invalidEvent("invalid panel lease reply")) }
          return .success(value)
        })
    }
  }

  public func closePanel(
    leaseID: UInt32, scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard leaseID > 0 else { throw ShaarEngineError.invalidEvent("invalid panel lease") }
    return try submitPanel(
      .panelClose, fields: ["leaseID": leaseID], scope: scope,
      windowID: windowID, tabID: tabID, completion: completion)
  }

  public func getPanelResponseBody(
    leaseID: UInt32, requestID: String, scope: ShaarNavigationScope,
    windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<ShaarDevToolsResponseBody, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard leaseID > 0, !requestID.isEmpty, requestID.utf8.count <= 128 else {
      throw ShaarEngineError.invalidEvent("invalid panel response request")
    }
    return try submitPanel(
      .panelGetResponseBody, fields: ["leaseID": leaseID, "requestID": requestID],
      scope: scope, windowID: windowID, tabID: tabID
    ) { result in
      completion(
        result.flatMap { data in
          guard let body = ShaarDevToolsResponseBody.decode(data) else {
            return .failure(.invalidEvent("invalid panel response body"))
          }
          return .success(body)
        })
    }
  }

  public func screencastCommand(
    _ command: ShaarDevToolsScreencastCommand, leaseID: UInt32,
    scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard leaseID > 0, let fields = command.fields else {
      throw ShaarEngineError.invalidEvent("invalid panel screencast command")
    }
    return try submitPanel(
      .panelScreencast, fields: fields.merging(["leaseID": leaseID]) { value, _ in value },
      scope: scope, windowID: windowID, tabID: tabID, completion: completion)
  }

  public func phase2Command(
    _ command: ShaarDevToolsPhase2Command, leaseID: UInt32,
    scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<ShaarDevToolsPhase2Reply, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard leaseID > 0, let parameters = command.parameters else {
      throw ShaarEngineError.invalidEvent("invalid phase 2 command")
    }
    return try submitPanel(
      .panelPhase2Command,
      fields: ["leaseID": leaseID, "commandID": command.id, "params": parameters],
      scope: scope, windowID: windowID, tabID: tabID
    ) { result in
      completion(
        result.flatMap { data in
          guard let reply = ShaarDevToolsPhase2Reply.decode(data, command: command) else {
            return .failure(.invalidEvent("invalid phase 2 reply"))
          }
          return .success(reply)
        })
    }
  }

  public func setPanelNetworkRules(
    _ rules: [ShaarDevToolsNetworkRule], leaseID: UInt32,
    scope: ShaarNavigationScope, windowID: String, tabID: String,
    completion: @escaping @Sendable (Result<Void, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard leaseID > 0, let rows = rules.networkRuleParameters else {
      throw ShaarEngineError.invalidEvent("invalid panel network rules")
    }
    return try submitPanel(
      .panelNetworkRules, fields: ["leaseID": leaseID, "rules": rows],
      scope: scope, windowID: windowID, tabID: tabID, maximumPayloadBytes: 2 * 1_048_576
    ) { result in
      completion(
        result.flatMap { data in
          guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["schemaVersion"], object["schemaVersion"] as? Int == 1
          else { return .failure(.invalidEvent("invalid network rules reply")) }
          return .success(())
        })
    }
  }

  private func submitPanel(
    _ operation: ShaarDevToolsOperation, fields: [String: Any],
    scope: ShaarNavigationScope, windowID: String, tabID: String,
    maximumPayloadBytes: Int? = nil,
    completion: @escaping @Sendable (Result<Data, ShaarEngineError>) -> Void
  ) throws -> UInt64 {
    guard !scope.profileID.isEmpty, scope.sessionID.map({ !$0.isEmpty }) ?? true,
      !windowID.isEmpty, !tabID.isEmpty
    else { throw ShaarEngineError.invalidEvent("invalid panel target") }
    var envelope = fields
    envelope["schemaVersion"] = 1
    let payload = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    if let maximumPayloadBytes, payload.count > maximumPayloadBytes {
      throw ShaarEngineError.invalidEvent("panel payload too large")
    }
    return try engine.submit(
      ShaarDevToolsRequest(
        operation: operation, scope: scope, windowID: windowID, tabID: tabID,
        payload: payload), completion: completion)
  }
}

public struct ShaarDevToolsFrontendState: Equatable, Sendable {
  public let open: Bool
}

public enum ShaarDevToolsEventRouter {
  public static func decodeFrontendState(
    _ event: ShaarCopiedEvent,
    scope: ShaarNavigationScope,
    windowID: String,
    tabID: String
  ) -> ShaarDevToolsFrontendState? {
    guard event.kind == 14,
      event.profileID == Data(scope.profileID.utf8),
      event.sessionID == Data((scope.sessionID ?? "").utf8),
      event.windowID == Data(windowID.utf8),
      event.tabID == Data(tabID.utf8),
      let payload = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      payload["schemaVersion"] as? Int == 1,
      payload["kind"] as? String == "frontendState",
      let open = devToolsJSONBoolean(payload["open"]),
      Set(payload.keys) == ["schemaVersion", "kind", "open"]
    else { return nil }
    return ShaarDevToolsFrontendState(open: open)
  }
}

extension ShaarEngineLoader {
  public func makeDevToolsAdapter(
    handleResolver: any ShaarNavigationHandleResolving
  ) throws -> ShaarDevToolsAdapter? {
    guard implementation == .shaar,
      let transport = try makeDevToolsTransport(handleResolver: handleResolver)
    else { return nil }
    return ShaarDevToolsAdapter(implementation: .shaar, engine: transport)
  }

  public func makeDevToolsTransport(
    handleResolver: any ShaarNavigationHandleResolving
  ) throws -> ShaarDevToolsABITransport? {
    guard implementation == .shaar else { return nil }
    return try ShaarDevToolsABITransport(resolver: self, handleResolver: handleResolver)
  }
}
