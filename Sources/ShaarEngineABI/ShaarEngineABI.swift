// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Darwin
import Foundation
import ShaarEngineC

/// Step 0 deliberately leaves shipping builds on the existing ChromiumBridge path.
public enum ShaarEngineImplementation: Equatable, Sendable {
  case ardia
  case shaar

  public static let shippingDefault: Self = .ardia
}

public enum ShaarEngineError: Error, Equatable, Sendable {
  case missingSymbol(String)
  case unsupportedABI(expected: UInt32, actual: UInt32)
  case invalidStatusCode(UInt32)
  case invalidEvent(String)
  case status(ShaarStatusCode, platformCode: Int32, message: String)
}

/// Numeric values are fixed by Design/shaar_engine.h and are never inferred from text.
public enum ShaarStatusCode: UInt32, CaseIterable, Sendable {
  case ok = 0
  case invalidArgument = 1
  case unsupportedABI = 2
  case notReady = 3
  case notFound = 4
  case wrongProfile = 5
  case wrongSession = 6
  case privateDisallowed = 7
  case policyBlocked = 8
  case permissionDenied = 9
  case conflict = 10
  case cancelled = 11
  case ioError = 12
  case chromiumError = 13
  case shuttingDown = 14
  case unsupportedCapability = 15
}

public struct ShaarCopiedEvent: Equatable, Sendable {
  public let sequence: UInt64
  public let kind: UInt32
  public let profileID: Data
  public let sessionID: Data
  public let windowID: Data
  public let tabID: Data
  public let payloadJSON: Data

  public init(
    sequence: UInt64, kind: UInt32, profileID: Data, sessionID: Data,
    windowID: Data, tabID: Data, payloadJSON: Data
  ) {
    self.sequence = sequence
    self.kind = kind
    self.profileID = profileID
    self.sessionID = sessionID
    self.windowID = windowID
    self.tabID = tabID
    self.payloadJSON = payloadJSON
  }
}

/// Compatibility names that refer directly to the imported C ABI types.
public typealias ShaarBytes = shaar_bytes
public typealias ShaarABIEvent = shaar_event

private func copyBytes(_ bytes: shaar_bytes, field: String) throws -> Data {
  guard bytes.size >= 0, bytes.size == 0 || bytes.data != nil else {
    throw ShaarEngineError.invalidEvent("invalid \(field) slice")
  }
  guard let pointer = bytes.data, bytes.size > 0 else { return Data() }
  return Data(bytes: pointer, count: bytes.size)
}

public enum ShaarEventCopy {
  public static func copy(_ event: ShaarABIEvent) throws -> ShaarCopiedEvent {
    let requiredSize = UInt32(MemoryLayout<ShaarABIEvent>.size)
    guard event.size >= requiredSize else {
      throw ShaarEngineError.invalidEvent("short event struct")
    }
    let profile = try copyBytes(event.profile_id, field: "profile ID")
    let session = try copyBytes(event.session_id, field: "session ID")
    let kind = UInt32(event.kind.rawValue)
    if kind != UInt32(SHAAR_EVENT_ENGINE.rawValue) && profile.isEmpty {
      throw ShaarEngineError.invalidEvent("profile-scoped event has no profile ID")
    }
    return ShaarCopiedEvent(
      sequence: event.sequence, kind: kind, profileID: profile,
      sessionID: session,
      windowID: try copyBytes(event.window_id, field: "window ID"),
      tabID: try copyBytes(event.tab_id, field: "tab ID"),
      payloadJSON: try copyBytes(event.payload_json, field: "payload JSON"))
  }
}

@MainActor public final class ShaarEventDispatcher {
  private let handler: @MainActor (ShaarCopiedEvent) -> Void
  public init(handler: @escaping @MainActor (ShaarCopiedEvent) -> Void) { self.handler = handler }

  /// Call from the C callback. Borrowed bytes are copied before the callback returns.
  public nonisolated func receive(_ borrowed: ShaarABIEvent) {
    let copied = try? ShaarEventCopy.copy(borrowed)
    guard let copied else { return }
    Task { @MainActor [weak self] in self?.handler(copied) }
  }
}

public protocol ShaarSymbolResolving {
  func symbol(named: String) -> UnsafeRawPointer?
}

private struct FrameworkSymbols: ShaarSymbolResolving {
  let handle: UnsafeMutableRawPointer
  func symbol(named: String) -> UnsafeRawPointer? {
    dlsym(handle, named).map(UnsafeRawPointer.init)
  }
}

public struct ShaarEngineLoader {
  public static let abiMajor: UInt32 = 1
  public let implementation: ShaarEngineImplementation
  private let abiMajorFunction: @convention(c) () -> UInt32
  public let createSymbol: UnsafeRawPointer
  private let symbolResolver: any ShaarSymbolResolving

  public init(resolver: ShaarSymbolResolving, implementation: ShaarEngineImplementation = .shaar)
    throws
  {
    guard let majorSymbol = resolver.symbol(named: "shaar_abi_major") else {
      throw ShaarEngineError.missingSymbol("shaar_abi_major")
    }
    guard let create = resolver.symbol(named: "shaar_engine_create") else {
      throw ShaarEngineError.missingSymbol("shaar_engine_create")
    }
    let major = unsafeBitCast(majorSymbol, to: (@convention(c) () -> UInt32).self)()
    guard major == Self.abiMajor else {
      throw ShaarEngineError.unsupportedABI(expected: Self.abiMajor, actual: major)
    }
    self.implementation = implementation
    self.symbolResolver = resolver
    self.abiMajorFunction = unsafeBitCast(majorSymbol, to: (@convention(c) () -> UInt32).self)
    self.createSymbol = create
  }

  public func currentMajor() -> UInt32 { abiMajorFunction() }

  public static func load(frameworkURL: URL, implementation: ShaarEngineImplementation = .shaar)
    throws -> Self
  {
    let binary = frameworkURL.appending(path: "Versions/Current/Chromium Framework")
    guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
      throw ShaarEngineError.missingSymbol(String(cString: dlerror()))
    }
    return try Self(resolver: FrameworkSymbols(handle: handle), implementation: implementation)
  }
}

extension ShaarEngineLoader: ShaarSymbolResolving {
  public func symbol(named: String) -> UnsafeRawPointer? {
    symbolResolver.symbol(named: named)
  }
}

extension ShaarStatusCode {
  public static func decode(_ rawValue: UInt32, platformCode: Int32 = 0, message: String = "")
    throws
  {
    guard let status = Self(rawValue: rawValue) else {
      throw ShaarEngineError.invalidStatusCode(rawValue)
    }
    guard status == .ok else {
      throw ShaarEngineError.status(status, platformCode: platformCode, message: message)
    }
  }
}
